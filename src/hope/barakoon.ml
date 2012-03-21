open Mem_store 
open Bstore
open Hub
open Lwt

module MyHub = HUB(BStore)

let gen_request_id =
  let c = ref 0 in
  fun () -> let r = !c in 
            let () = incr c in 
            r

module C = struct
  open Common
  type t = TODO

  let prologue (ic,oc) = 
    let check magic version = 
      if magic = _MAGIC && 
        version = _VERSION 
      then Lwt.return ()
      else Llio.lwt_failfmt "MAGIC %lx or VERSION %x mismatch" magic version
    in
    let check_cluster cluster_id = 
      let ok = true in
      if ok then Lwt.return ()
      else Llio.lwt_failfmt "WRONG CLUSTER: %s" cluster_id
    in
    Llio.input_int32  ic >>= fun magic ->
    Llio.input_int    ic >>= fun version ->
    check magic version  >>= fun () ->
    Llio.input_string ic >>= fun cluster_id ->
    check_cluster cluster_id >>= fun () ->
    Lwt.return ()
    
  let __do_unit_update hub q =
    let id = gen_request_id () in
    MyHub.update hub id q >>= fun a ->
    match a with 
      | Core.UNIT -> Lwt.return ()

  let _set hub k v = 
    let q = Core.SET(k,v) in
    __do_unit_update hub q

  let _delete hub k =
    let q = Core.DELETE k in
    __do_unit_update hub q

  let _get hub k = MyHub.get hub k


  let one_command hub ((ic,oc) as conn) = 
    Client_protocol.read_command conn >>= fun comm ->
    match comm with
      | WHO_MASTER ->
        _log "who master" >>= fun () ->
        let mo = Some "arakoon_0" in
        Llio.output_int32 oc 0l >>= fun () ->
        Llio.output_string_option oc mo >>= fun () ->
        Lwt.return false
      | SET -> 
        begin
          Llio.input_string ic >>= fun key ->
          Llio.input_string ic >>= fun value ->
          _log "set %S %S" key value >>= fun () ->
          Lwt.catch
            (fun () -> 
              _set hub key value >>= fun () ->
              Client_protocol.response_ok_unit oc)
            (Client_protocol.handle_exception oc)
        end
      | GET ->
        begin
          Llio.input_bool ic >>= fun allow_dirty ->
          Llio.input_string ic >>= fun key ->
          _log "get %S" key >>= fun () ->
          Lwt.catch 
            (fun () -> 
              _get hub key >>= fun value ->
              Client_protocol.response_rc_string oc 0l value)
            (Client_protocol.handle_exception oc)
        end 

  let protocol hub (ic,oc) =   
    let rec loop () = 
      begin
        one_command hub (ic,oc) >>= fun stop ->
        if stop
        then _log "end of session"
        else 
          begin
            Lwt_io.flush oc >>= fun () ->
            loop ()
          end
      end
    in
    _log "session started" >>= fun () ->
    prologue(ic,oc) >>= fun () -> 
    _log "prologue ok" >>= fun () ->
    loop ()

end

module MC = struct
  (* TODO Copied *)
  let __do_unit_update hub q =
    let id = gen_request_id () in
    MyHub.update hub id q >>= fun a ->
    match a with
      | Core.UNIT -> Lwt.return ()

  let _set hub k v =
    let q = Core.SET(k,v) in
    __do_unit_update hub q

  let _delete hub k =
    let q = Core.DELETE k in
    __do_unit_update hub q

  let one_command hub ((ic, oc) as conn) =
    Memcache_protocol.read_command conn >>= fun comm ->
    match comm with
      | Memcache_protocol.GET keys ->
          begin
            _log "Memcache GET" >>= fun () ->
            Lwt.catch
              (fun () ->
                (* TODO This pulls everything in memory first. We might want to
                 * emit key/value pairs one by one instead *)
                Lwt_list.fold_left_s
                  (fun acc key ->
                    Lwt.catch
                      (fun () ->
                        MyHub.get hub key >>= fun value ->
                        Lwt.return ((key, value) :: acc))
                      (fun _ ->
                        Lwt.return acc))
                  [] keys
                >>=
                Memcache_protocol.response_get oc)
              (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.SET (key, value, noreply) ->
          begin
            _log "Memcache SET" >>= fun () ->
            Lwt.catch
            (fun () ->
              _set hub key value >>= fun () ->
              if noreply
              then
                Lwt.return false
              else
                Memcache_protocol.response_set oc)
            (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.DELETE (key, noreply) ->
          begin
            _log "Memcache DELETE" >>= fun () ->
            Lwt.catch
            (fun () ->
              _delete hub key >>= fun () ->
              (* TODO Handle NOT_FOUND *)
              if noreply
              then
                Lwt.return false
              else
                Memcache_protocol.response_delete oc true)
            (Memcache_protocol.handle_exception oc)
          end
      | Memcache_protocol.VERSION ->
          begin
            _log "Memcache VERSION" >>= fun () ->
            Memcache_protocol.response_version oc Version.git_info
          end
      | Memcache_protocol.QUIT ->
          begin
            _log "Memcache QUIT" >>= fun () ->
            Lwt.return true
          end
      | Memcache_protocol.ERROR ->
          begin
            _log "Memcache ERROR" >>= fun () ->
            Lwt.return true
          end

  let protocol hub (ic, oc) =
    _log "Memcache session started" >>= fun () ->
    let rec loop () =
      begin
        one_command hub (ic, oc) >>= fun stop ->
        if stop
        then _log "End of memcache session"
        else
          begin
            Lwt_io.flush oc >>= fun () ->
            loop ()
          end
      end
    in
    loop ()
end

let server_t hub =
  let host = "127.0.0.1" 
  and port = 4000 in
  let inner = Server.make_server_thread host port (C.protocol hub) in
  inner ()

let mc_server_t hub =
  let host = "127.0.0.1"
  and port = 11211 in
  let inner = Server.make_server_thread host port (MC.protocol hub) in
  inner ()

let log_prelude () = 
  _log "--- NODE STARTED ---" >>= fun () ->
  _log "git info: %s " Version.git_info >>= fun () ->
  _log "compile_time: %s " Version.compile_time >>= fun () ->
  _log "machine: %s " Version.machine 


let main_t () =
  let hub = MyHub.create () in
  let service hub = server_t hub in
  let mc_service hub = mc_server_t hub in
  log_prelude () >>= fun () ->
  Lwt.join [ MyHub.serve hub;
             service hub;
             mc_service hub
           ];;

let () =  Lwt_main.run (main_t())
  