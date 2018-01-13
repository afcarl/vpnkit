open Lwt.Infix
open Astring

let src =
  let src = Logs.Src.create "http" ~doc:"Transparently proxy HTTP" in
  Logs.Src.set_level src (Some Logs.Info);
  src

module Log = (val Logs.src_log src : Logs.LOG)

let errorf fmt = Fmt.kstrf (fun e -> Lwt.return (Error (`Msg e))) fmt

module Exclude = struct

  module One = struct
    module Element = struct
      (* One element of a DNS name *)
      type t = Any | String of string

      let of_string = function
      | "*" -> Any
      | x -> String x

      let to_string = function
      | Any -> "*"
      | String x -> x

      let matches x = function
      | Any -> true
      | String y -> x = y
    end

    type t =
      | Subdomain of Element.t list
      | CIDR of Ipaddr.V4.Prefix.t

    let of_string s =
      match Ipaddr.V4.Prefix.of_string s with
      | None ->
        let bits = Astring.String.cuts ~sep:"." s in
        Subdomain (List.map Element.of_string bits)
      | Some prefix -> CIDR prefix

    let to_string = function
    | Subdomain x ->
      "Subdomain " ^ String.concat ~sep:"." @@ List.map Element.to_string x
    | CIDR prefix -> "CIDR " ^ Ipaddr.V4.Prefix.to_string prefix

    let matches dst req = function
    | CIDR prefix -> Ipaddr.V4.Prefix.mem dst prefix
    | Subdomain domains ->
      begin match req with
      | Some req ->
        let h = req.Cohttp.Request.headers in
        begin match Cohttp.Header.get h "host" with
        | Some host ->
          let bits = Astring.String.cuts ~sep:"." host in
          (* does 'bits' match 'domains' *)
          let rec loop bits domains = match bits, domains with
          | _, [] -> true
          | [], _ :: _ -> false
          | b :: bs, d :: ds -> Element.matches b d && loop bs ds in
          loop (List.rev bits) (List.rev domains)
        | None -> false
        end
      | None -> false
      end
  end

  type t = One.t list

  let none = []

  let of_string s =
    let open Astring in
    (* Accept either space or comma-separated ignoring whitespace *)
    let parts =
      String.fields ~empty:false
        ~is_sep:(fun c -> c = ',' || Char.Ascii.is_white c) s
    in
    List.map One.of_string parts

  let to_string t = String.concat ~sep:" " @@ (List.map One.to_string t)

  let matches dst req t =
    List.fold_left (||) false (List.map (One.matches dst req) t)

end

let error_html title body =
  Printf.sprintf
"<html><head>
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">
<title>%s</title>
</head><body>
%s
<br>
<p>Server is <a href=\"https://github.com/moby/vpnkit\">moby/vpnkit</a></p>
</body>
</html>
" title body

module Make
    (Ip: Mirage_protocols_lwt.IPV4)
    (Udp: Mirage_protocols_lwt.UDPV4)
    (Tcp:Mirage_flow_lwt.SHUTDOWNABLE)
    (Socket: Sig.SOCKETS)
    (Dns_resolver: Sig.DNS)
= struct

  type proxy = Uri.t

  let string_of_proxy = Uri.to_string
  let proxy_of_string = Uri.of_string


  let string_of_address (ip, port) = Fmt.strf "%s:%d" (Ipaddr.to_string ip) port

  type t = {
    http: proxy option;
    https: proxy option;
    exclude: Exclude.t;
  }

  let resolve_ip name_or_ip =
    match Ipaddr.of_string name_or_ip with
    | None ->
      let open Dns.Packet in
      let question =
        make_question ~q_class:Q_IN Q_A (Dns.Name.of_string name_or_ip)
      in
      Dns_resolver.resolve question
      >>= fun rrs ->
      (* Any IN record will do (NB it might be a CNAME) *)
      let rec find_ip = function
        | { cls = RR_IN; rdata = A ipv4; _ } :: _ ->
          Lwt.return (Ok (Ipaddr.V4 ipv4))
        | _ :: rest -> find_ip rest
        | [] -> errorf "Failed to lookup host: %s" name_or_ip in
      find_ip rrs
    | Some x -> Lwt.return (Ok x)

  let to_json t =
    let open Ezjsonm in
    let http = match t.http with
    | None   -> []
    | Some x -> [ "http",  string @@ string_of_proxy x ]
    in
    let https = match t.https with
    | None   -> []
    | Some x -> [ "https", string @@ string_of_proxy x ]
    in
    let exclude = [ "exclude", string @@ Exclude.to_string t.exclude ] in
    dict (http @ https @ exclude)

  let of_json j =
    let open Ezjsonm in
    let http =
      try Some (get_string @@ find j [ "http" ])
      with Not_found -> None
    in
    let https =
      try Some (get_string @@ find j [ "https" ])
      with Not_found -> None
    in
    let exclude =
      try Exclude.of_string @@ get_string @@ find j [ "exclude" ]
      with Not_found -> Exclude.none
    in
    let http = match http with None -> None | Some x -> Some (proxy_of_string x) in
    let https = match https with None -> None | Some x -> Some (proxy_of_string x) in
    Lwt.return (Ok { http; https; exclude })

  let to_string t = Ezjsonm.to_string ~minify:false @@ to_json t

  let create ?http ?https ?exclude:_ () =
    let http = match http with None -> None | Some x -> Some (proxy_of_string x) in
    let https = match https with None -> None | Some x -> Some (proxy_of_string x) in
    (* FIXME: parse excludes *)
    let exclude = [] in
    let t = { http; https; exclude } in
    Log.info (fun f -> f "HTTP proxy settings changed to: %s" (to_string t));
    Lwt.return (Ok t)

  module Incoming = struct
    module C = Mirage_channel_lwt.Make(Tcp)
    module IO = Cohttp_mirage_io.Make(C)
    module Request = Cohttp.Request.Make(IO)
    module Response = Cohttp.Response.Make(IO)
  end
  module Outgoing = struct
    module C = Mirage_channel_lwt.Make(Socket.Stream.Tcp)
    module IO = Cohttp_mirage_io.Make(C)
    module Request = Cohttp.Request.Make(IO)
    module Response = Cohttp.Response.Make(IO)
  end

  let rec proxy_body_request ~reader ~writer =
    let open Cohttp.Transfer in
    Incoming.Request.read_body_chunk reader >>= function
    | Done          -> Lwt.return_unit
    | Final_chunk x -> Outgoing.Request.write_body writer x
    | Chunk x       ->
      Outgoing.Request.write_body writer x >>= fun () ->
      proxy_body_request ~reader ~writer

  let rec proxy_body_response ~reader ~writer =
    let open Cohttp.Transfer in
    Outgoing.Response.read_body_chunk reader  >>= function
    | Done          -> Lwt.return_unit
    | Final_chunk x -> Incoming.Response.write_body writer x
    | Chunk x       ->
      Incoming.Response.write_body writer x >>= fun () ->
      proxy_body_response ~reader ~writer

  (* Take a request and a pair (incoming, outgoing) of channels, send
     the request to the outgoing channel and then proxy back any response. *)
  let proxy_request ~description ~incoming ~outgoing ~req =
    let reader = Incoming.Request.make_body_reader req incoming in
    Outgoing.Request.write ~flush:true (fun writer ->
        match Incoming.Request.has_body req with
        | `Yes     -> proxy_body_request ~reader ~writer
        | `No      -> Lwt.return_unit
        | `Unknown ->
          Log.warn (fun f ->
              f "Request.has_body returned `Unknown: not sure what \
                  to do");
          Lwt.return_unit
      ) req outgoing
    >>= fun () ->
    Outgoing.Response.read outgoing >>= function
    | `Eof ->
      Log.warn (fun f -> f "%s: EOF" (description false));
      Lwt.return_unit
    | `Invalid x ->
      Log.warn (fun f ->
          f "%s: Failed to parse HTTP response: %s"
            (description false) x);
      Lwt.return_unit
    | `Ok res ->
      Log.info (fun f ->
          f "%s: %s %s"
            (description false)
            (Cohttp.Code.string_of_version res.Cohttp.Response.version)
            (Cohttp.Code.string_of_status res.Cohttp.Response.status));
      Log.debug (fun f ->
          f "%s" (Sexplib.Sexp.to_string_hum
                    (Cohttp.Response.sexp_of_t res)));
      let reader = Outgoing.Response.make_body_reader res outgoing in
      Incoming.Response.write ~flush:true (fun writer ->
          match Cohttp.Request.meth req, Incoming.Response.has_body res with
          | `HEAD, `Yes ->
            (* Bug in cohttp.1.0.2: according to Section 9.4 of RFC2616
               https://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html
               > The HEAD method is identical to GET except that the server
               > MUST NOT return a message-body in the response.
            *)
            Log.debug (fun f -> f "%s: HEAD requests MUST NOT have response bodies" (description false));
            Lwt.return_unit
          | _, `Yes     ->
            Log.info (fun f -> f "%s: proxying body" (description false));
            proxy_body_response ~reader ~writer
          | _, `No      ->
            Log.info (fun f -> f "%s: no body to proxy" (description false));
            Lwt.return_unit
          | _, `Unknown ->
            Log.warn (fun f ->
                f "Response.has_body returned `Unknown: not sure \
                    what to do");
            Lwt.return_unit
        ) res incoming

  let transparent_proxy_http_one ~dst ~t proxy incoming =
    Incoming.Request.read incoming >>= function
    | `Eof -> Lwt.return_unit
    | `Invalid x ->
      Log.warn (fun f ->
          f "Failed to parse HTTP request on port %a:80: %s"
            Ipaddr.V4.pp_hum dst x);
      Lwt.return_unit
    | `Ok req ->
      (* An HTTP request will have a missing scheme so we fill it in.
         An HTTP proxy request will have a scheme already so we keep it.
         An HTTPS proxy request will be a CONNECT host:port *)
      let uri =
        let original = Cohttp.Request.uri req in
        match Uri.scheme original with
        | None -> Uri.with_scheme original (Some "http")
        | Some _ -> original in
      (
        if Exclude.matches dst (Some req) t.exclude
        then Lwt.return (Ok (Ipaddr.V4 dst, 80)) (* direct connection *)
        else begin match Uri.host proxy, Uri.port proxy with
        | None, _ ->
          Lwt.return (Error (`Msg ("HTTP proxy URI does not include a hostname: " ^ (Uri.to_string proxy))))
        | _, None ->
          Lwt.return (Error (`Msg ("HTTP proxy URI does not include a port: " ^ (Uri.to_string proxy))))
        | Some host, Some port ->
          resolve_ip host
          >>= function
          | Error e -> Lwt.return (Error e)
          | Ok ip -> Lwt.return (Ok (ip, port))
        end
      ) >>= function
      | Error (`Msg m) ->
        Log.err (fun f -> f "HTTP proxy: cannot forward to %s: %s" (Uri.to_string proxy) m);
        Lwt.return_unit (* FIXME: should force a close *)
      | Ok address ->
        begin
          (* Log the request to the console *)
          let description outgoing =
            Printf.sprintf "%s:80 %s %s:%d Host:%s"
              (Ipaddr.V4.to_string dst)
              (if outgoing then "-->" else "<--")
              (Ipaddr.to_string @@ fst address)
              (snd address)
              (match Uri.host uri with Some x -> x | None -> "(unknown host)")
          in
          Log.info (fun f ->
              f "%s: %s %s"
                (description true)
                (Cohttp.(Code.string_of_method (Cohttp.Request.meth req)))
                (Uri.path uri));
          Socket.Stream.Tcp.connect address >>= function
          | Error _ ->
            Log.err (fun f ->
                f "Failed to connect to %s" (string_of_address address));
            Lwt.return_unit
          | Ok remote ->
            (* Consider the proxy-authorization header: we must erase any existing
               one and add one of our own, if necessary. *)
            let proxy_authorization = "Proxy-Authorization" in
            let headers = Cohttp.Header.remove req.Cohttp.Request.headers proxy_authorization in
            let headers = match Uri.userinfo proxy with
              | None -> headers
              | Some s -> Cohttp.Header.add headers proxy_authorization ("Basic " ^ (B64.encode s)) in
            (* Make the resource a full URI *)
            let req = { req with Cohttp.Request.resource = Uri.to_string uri; headers } in
            Lwt.finalize (fun () ->
                let outgoing = Outgoing.C.create remote in
                proxy_request ~description ~incoming ~outgoing ~req
            ) (fun () -> Socket.Stream.Tcp.close remote)
        end

  let transparent_http ~dst ~t h =
    let listeners _port =
      Log.debug (fun f -> f "HTTP TCP handshake complete");
      let f flow =
        Lwt.finalize (fun () ->
            let incoming = Incoming.C.create flow in
            let rec loop () = transparent_proxy_http_one ~dst ~t h incoming >>= loop in
            loop ()
          ) (fun () -> Tcp.close flow)
      in
      Some f
    in
    Lwt.return listeners

  (* forward outgoing to ingoing *)
  let a_t flow ~incoming ~outgoing =
    let warn pp e =
      Log.warn (fun f -> f "Unexpected exeption %a in proxy" pp e);
    in
    let rec loop () =
      (Outgoing.C.read_some outgoing >>= function
        | Ok `Eof        -> Lwt.return false
        | Error e        -> warn Outgoing.C.pp_error e; Lwt.return false
        | Ok (`Data buf) ->
          Incoming.C.write_buffer incoming buf;
          Incoming.C.flush incoming >|= function
          | Ok ()         -> true
          | Error `Closed -> false
          | Error e       -> warn Incoming.C.pp_write_error e; false
      ) >>= fun continue ->
      if continue then loop () else Tcp.shutdown_write flow
    in
    loop ()

  (* forward ingoing to outgoing *)
  let b_t remote ~incoming ~outgoing =
    let warn pp e =
      Log.warn (fun f -> f "Unexpected exeption %a in proxy" pp e);
    in
    let rec loop () =
      (Incoming.C.read_some incoming >>= function
        | Ok `Eof        -> Lwt.return false
        | Error e        -> warn Incoming.C.pp_error e; Lwt.return false
        | Ok (`Data buf) ->
          Outgoing.C.write_buffer outgoing buf;
          Outgoing.C.flush outgoing >|= function
          | Ok ()         -> true
          | Error `Closed -> false
          | Error e       -> warn Outgoing.C.pp_write_error e; false
      ) >>= fun continue ->
      if continue then loop () else Socket.Stream.Tcp.shutdown_write remote
    in
    loop ()

  let transparent_https ~dst proxy =
    let listeners _port =
      Log.debug (fun f -> f "HTTPS TCP handshake complete");
      let f flow =
        (
          match Uri.host proxy, Uri.port proxy with
          | None, _ ->
            Lwt.return (Error (`Msg ("HTTP proxy URI does not include a hostname: " ^ (Uri.to_string proxy))))
          | _, None ->
            Lwt.return (Error (`Msg ("HTTP proxy URI does not include a port: " ^ (Uri.to_string proxy))))
          | Some host, Some port ->
            resolve_ip host
            >>= function
            | Error e -> Lwt.return (Error e)
            | Ok ip -> Lwt.return (Ok (ip, port))
      ) >>= function
      | Error (`Msg m) ->
        Log.err (fun f -> f "HTTP proxy: cannot forward to %s: %s" (Uri.to_string proxy) m);
        Lwt.return_unit
      | Ok ((ip, port) as address) ->
        Lwt.finalize (fun () ->
            let host = Ipaddr.V4.to_string dst in
            let description outgoing =
              Fmt.strf "%s:443 %s %s:%d" host
                (if outgoing then "-->" else "<--") (Ipaddr.to_string ip) port
            in
            Log.info (fun f -> f "%s: CONNECT" (description true));
            let connect =
              let host = Ipaddr.V4.to_string dst in
              let port = 443 in
              let uri = Uri.make ~host ~port () in
              let empty_headers = Cohttp.Header.init () in
              let headers = match Uri.userinfo proxy with
                | None -> empty_headers
                | Some s -> Cohttp.Header.add empty_headers "Proxy-Authorization" ("Basic " ^ (B64.encode s)) in
              let request = Cohttp.Request.make ~meth:`CONNECT ~headers uri in
              { request with Cohttp.Request.resource = host ^ ":" ^ (string_of_int port) }
            in
            Socket.Stream.Tcp.connect address >>= function
            | Error _ ->
              Log.err (fun f ->
                  f "Failed to connect to %s" (string_of_address address));
              Lwt.return_unit
            | Ok remote ->
              let outgoing = Outgoing.C.create remote in
              Lwt.finalize  (fun () ->
                  Outgoing.Request.write ~flush:true (fun _ -> Lwt.return_unit)
                    connect outgoing
                  >>= fun () ->
                  Outgoing.Response.read outgoing >>= function
                  | `Eof ->
                    Log.warn (fun f ->
                        f "EOF from %s" (string_of_address address));
                    Lwt.return_unit
                  | `Invalid x ->
                    Log.warn (fun f ->
                        f "Failed to parse HTTP response on port %s: %s"
                          (string_of_address address) x);
                    Lwt.return_unit
                  | `Ok res ->
                    Log.info (fun f ->
                        let open Cohttp.Response in
                        f "%s: %s %s"
                          (description false)
                          (Cohttp.Code.string_of_version res.version)
                          (Cohttp.Code.string_of_status res.status));
                    Log.debug (fun f ->
                        f "%s" (Sexplib.Sexp.to_string_hum
                                  (Cohttp.Response.sexp_of_t res)));
                    (* Since we've already layered a channel on top,
                       we can't use the Mirage_flow.proxy since it
                       would miss the contents already
                       buffered. Therefore we write out own
                       channel-level proxy here: *)
                    let incoming = Incoming.C.create flow in
                    Lwt.join [
                      a_t flow ~incoming ~outgoing;
                      b_t remote ~incoming ~outgoing
                    ]
                ) (fun () -> Socket.Stream.Tcp.close remote)
          ) (fun () -> Tcp.close flow)
      in Some f
    in
    Lwt.return listeners

  let fetch_direct ~flow incoming =
    Incoming.Request.read incoming >>= function
    | `Eof -> Lwt.return false
    | `Invalid x ->
      Log.warn (fun f ->
          f "HTTP proxy failed to parse HTTP request: %s"
            x);
      Lwt.return false
    | `Ok req ->
      let uri = Cohttp.Request.uri req in
      let meth = Cohttp.Request.meth req in
      let port = match Uri.port uri with Some x -> x | None -> 80 in
      begin match Uri.host uri with
      | None ->
        Log.err (fun f ->
          f "HTTP proxy URI must contain a host element: %s"
            (Uri.to_string uri)
        );
        let res = Cohttp.Response.make ~version:`HTTP_1_1 ~status:`Bad_request () in
        Log.info (fun f -> f "HTTP proxy returning 400 Bad_request");
        Incoming.Response.write ~flush:true (fun writer ->
          Incoming.Response.write_body writer
          (error_html "ERROR: HTTP request is malformed"
            "The HTTP request must contain an absolute URI e.g. http://github.com/moby/vpnkit"
          )
        ) res incoming
        >>= fun () ->
        Lwt.return false
      | Some host ->
        resolve_ip host
        >>= function
        | Error (`Msg m) ->
          Log.err (fun f ->
            f "HTTP proxy failed to resolve %s: %s"
              (Uri.to_string uri) m
          );
          let res = Cohttp.Response.make ~version:`HTTP_1_1 ~status:`Service_unavailable () in
          Log.info (fun f -> f "HTTP proxy returning 503 Service_unavailable");
          Incoming.Response.write ~flush:true (fun writer ->
            Incoming.Response.write_body writer
            (error_html "ERROR: DNS resolution failed"
              (Printf.sprintf "The hostname %s could not be resolved." host)
            )
          ) res incoming
          >>= fun () ->
          Lwt.return false
        | Ok ipv4 ->
          let address = ipv4, port in
          let description outgoing =
            Printf.sprintf "HTTP proxy %s %s:%d Host:%s"
              (if outgoing then "-->" else "<--")
              (Ipaddr.to_string @@ fst address)
              (snd address)
              host
          in
          Log.info (fun f ->
              f "%s: %s %s"
                (description true)
                (Cohttp.(Code.string_of_method meth))
                (Uri.path uri));
          begin Socket.Stream.Tcp.connect address >>= function
          | Error _ ->
            Log.err (fun f ->
                f "%s: Failed to connect to %s" (description true) (string_of_address address));
            let res = Cohttp.Response.make ~version:`HTTP_1_1 ~status:`Service_unavailable () in
            Log.info (fun f -> f "%s: returning 503 Service_unavailable" (description false));
            Incoming.Response.write ~flush:true (fun writer ->
              Incoming.Response.write_body writer
              (error_html "ERROR: connection refused"
                (Printf.sprintf "The proxy could not connect to %s" (string_of_address address))
              )
            ) res incoming
            >>= fun () ->
            Lwt.return false
          | Ok remote ->
            Lwt.finalize  (fun () ->
              Log.info (fun f ->
                  f "%s: Successfully connected to %s" (description true) (string_of_address address));
              let outgoing = Outgoing.C.create remote in
              match Cohttp.Request.meth req with
              | `CONNECT ->
                (* return 200 OK and start a TCP proxy *)
                let response = "HTTP/1.1 200 OK\r\n\r\n" in
                Incoming.C.write_string incoming response 0 (String.length response);
                begin Incoming.C.flush incoming >>= function
                | Error _ ->
                  Log.err (fun f -> f "%s: failed to return 200 OK" (description false));
                  Lwt.return false
                | Ok () ->
                  Lwt.join [
                    a_t flow ~incoming ~outgoing;
                    b_t remote ~incoming ~outgoing
                  ]
                  >>= fun () ->
                  Log.debug (fun f -> f "%s: HTTP CONNECT complete" (description false));
                  Lwt.return false
                end
              | _ ->
                (* The absolute URI used by the proxy should be converted back into
                   a relative URI and a Host: header *)
                (* https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.23 says that the port
                   number must be included if it's not 80. *)
                let host_and_port = host ^ (match Uri.port uri with None -> "" | Some port -> ":" ^ (string_of_int port)) in
                let req = { req with
                  Cohttp.Request.headers = Cohttp.Header.replace req.Cohttp.Request.headers "host" host_and_port;
                  resource = Uri.path_and_query uri
                } in
                Log.debug (fun f -> f "%s: sending %s"
                  (description false)
                  (Sexplib.Sexp.to_string_hum
                   (Cohttp.Request.sexp_of_t req))
                );
                proxy_request ~description ~incoming ~outgoing ~req
                >>= fun () ->
                Lwt.return true
            ) (fun () -> Socket.Stream.Tcp.close remote)
          end
    end

  (* A regular, non-transparent HTTP proxy implementation. *)
  let proxy () =
    let listeners _port =
      Log.debug (fun f -> f "HTTP TCP handshake complete");
      let f flow =
        Lwt.finalize (fun () ->
            let incoming = Incoming.C.create flow in
            let rec loop () =
              fetch_direct ~flow incoming
              >>= function
              | true ->
                (* keep the connection open, read more requests *)
                loop ()
              | false ->
                Log.debug (fun f -> f "HTTP session complete, closing connection");
                Lwt.return_unit in
            loop ()
          ) (fun () -> Tcp.close flow)
      in
      Some f
    in
    Lwt.return listeners

  let tcp ~dst:(original_ip, original_port) proxy =
    let listeners _port =
      let f flow =
        (
          match Uri.host proxy, Uri.port proxy with
          | None, _ ->
            Lwt.return (Error (`Msg ("HTTP proxy URI does not include a hostname: " ^ (Uri.to_string proxy))))
          | _, None ->
            Lwt.return (Error (`Msg ("HTTP proxy URI does not include a port: " ^ (Uri.to_string proxy))))
          | Some host, Some port ->
            resolve_ip host
            >>= function
            | Error e -> Lwt.return (Error e)
            | Ok ip -> Lwt.return (Ok (ip, port))
      ) >>= function
      | Error (`Msg m) ->
        Log.err (fun f -> f "HTTP proxy: cannot forward to %s: %s" (Uri.to_string proxy) m);
        Lwt.return_unit
      | Ok ((ip, port) as address) ->
        Lwt.finalize (fun () ->
            let description =
              Fmt.strf "%s:%d %s %s:%d" (Ipaddr.V4.to_string original_ip) original_port
                "-->" (Ipaddr.to_string ip) port
            in
            Log.debug (fun f -> f "%s: HTTP proxy TCP handshake complete" description);
            Socket.Stream.Tcp.connect address >>= function
            | Error _ ->
              Log.err (fun f ->
                  f "%s: Failed to connect to %s" description (string_of_address address));
              Lwt.return_unit
            | Ok remote ->
              let outgoing = Outgoing.C.create remote in
              Lwt.finalize  (fun () ->
                    let incoming = Incoming.C.create flow in
                    Lwt.join [
                      a_t flow ~incoming ~outgoing;
                      b_t remote ~incoming ~outgoing
                    ]
                ) (fun () -> Socket.Stream.Tcp.close remote)
          ) (fun () -> Tcp.close flow)
      in Some f
    in
    Lwt.return listeners

  let transparent_proxy_handler ~dst:(ip, port) ~t =
    match port, t.http, t.https with
    | 80, Some h, _ -> Some (transparent_http ~dst:ip ~t h)
    | 443, _, Some h ->
      if Exclude.matches ip None t.exclude
      then None
      else Some (transparent_https ~dst:ip h)
    | _, _, _ -> None

  let explicit_proxy_handler ~dst:(ip, port) ~t =
    match port, t.http, t.https with
    (* If we have an upstream HTTP proxy then proxy port 3128 at the TCP level *)
    | 3128, Some h, _ -> Some (tcp ~dst:(ip, port) h)
    (* If we have no upstream HTTP proxy then act as a proxy ourselves *)
    | 3128, None, _ -> Some (proxy ())
    (* If we have an upstream HTTPS proxy then proxy port 3129 at the TCP level *)
    | 3129, _, Some h -> Some (tcp ~dst:(ip, port) h)
    (* If we have no upstream HTTPS proxy then act as a proxy ourselves *)
    | 3129, _, None -> Some (proxy ())
    (* For other ports, refuse the connection *)
    | _, _, _ -> None
end
