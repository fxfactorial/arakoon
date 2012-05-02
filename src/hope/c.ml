open Lwt
open Modules

let _MAGIC = 0xb1ff0000l
let _MASK  = 0x0000ffffl
let _VERSION = 2

let my_read_command (ic,oc) = 
  let s = 8 in
  let h = String.create s in
  Lwt_io.read_into_exactly ic h 0 s >>= fun () ->
  Lwtc.log "my_read_command: h=%S" h >>= fun () ->
  let masked,p0 = Llio.int32_from h 4 in
  let magic = Int32.logand masked _MAGIC in
  if magic <> _MAGIC 
  then 
    begin
      Llio.output_int32 oc 1l >>= fun () ->
      Lwtc.failfmt "%08lx has no magic masked" masked
    end
  else
    begin
      let as_int32 = Int32.logand masked _MASK in
      try
        let c = Common.lookup_code as_int32 in
        let size,_   = (Llio.int_from h 0) in
        let rest_size = size -4 in
        let rest = String.create rest_size in
        Lwt_io.read_into_exactly ic rest 0 rest_size >>= fun () ->
        Lwt.return (c, Baardskeerder.Pack.make_input rest 0)
      with Not_found ->
        Llio.output_int32 oc 5l >>= fun () ->
        let msg = Printf.sprintf "%08lx: command not found" as_int32 in
        Llio.output_string oc msg >>= fun () ->
        Lwt.fail (Failure msg)
    end
open Baardskeerder    
module ProtocolHandler (S:Core.STORE) = struct      
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
      
  let get_key ic =
    Llio.input_string ic
      
  let get_range_params ic =
    Llio.input_bool ic >>= fun allow_dirty ->
    Llio.input_string_option ic >>= fun (first:string option) ->
    Llio.input_bool ic >>= fun finc  ->
    Llio.input_string_option ic >>= fun (last:string option)  ->
    Llio.input_bool ic >>= fun linc  ->
    Llio.input_int ic >>= fun max   ->
    Lwt.return (allow_dirty, first, finc, last, linc, max)
    
  let send_string_option oc so =
    Llio.output_int oc 0 >>= fun () ->
    Llio.output_string_option oc so 
      
  let __do_unit_update driver q =
    DRIVER.push_cli_req driver q >>= fun a ->
    match a with 
      | Core.UNIT -> Lwt.return ()
      | Core.FAILURE (rc, msg) -> failwith msg
      | Core.VALUE v -> failwith "Expected unit, not value"
	
  let _set driver k v = 
    let q = Core.SET(k,v) in
    __do_unit_update driver q
      
  let _sequence driver sequence = __do_unit_update driver sequence
    
  let _delete driver k =
    let q = Core.DELETE k in
    __do_unit_update driver q
      
  let wrap_not_found f d k =
    Lwt.catch 
      (fun () -> f d k >>= fun k -> Lwt.return (Some k))
      (function 
	| Not_found -> Lwt.return None
	| e -> Lwt.fail e
      )
      
  let _safe_get = S.get 
    
  let _get store k = 
    _safe_get store k >>= function
      | None -> Lwt.fail (Common.XException(Arakoon_exc.E_NOT_FOUND, k))
      | Some v -> Lwt.return v 
	
  let _safe_get = wrap_not_found _get 
    
  let extract_master_info = function
    | None -> None
    | Some s -> 
      begin
        let m, off = Llio.string_option_from s 0 in
	m
      end
          
  let am_i_master store me = 
    S.get_meta store >>= fun meta ->
    match (extract_master_info meta) with
      | Some m when m = me -> Lwt.return true
      | _ -> Lwt.return false
  
  let _get_meta store = S.get_meta store 
    
  let _last_entries store i oc = S.last_entries store (Core.TICK i) oc
    

  let one_command me driver store ((ic,oc) as conn) =    
    let only_if_master allow_dirty f =
      am_i_master store me >>= fun me_master ->
      Lwt.catch
      (fun () -> 
        if me_master || allow_dirty
        then             
          f ()
        else
          Lwt.fail (Common.XException(Arakoon_exc.E_NOT_MASTER, me))
      ) 
      (Client_protocol.handle_exception oc)
    in
    let _do_range inner output = 
      get_range_params ic >>= fun (allow_dirty, first, finc, last, linc, max) ->
      only_if_master allow_dirty 
        (fun () -> 
          inner store first finc last linc max >>= fun l ->
          Llio.output_int oc 0 >>= fun () ->
          output oc l >>= fun () ->
          Lwt.return false
        )
    in 
    my_read_command conn >>= fun (comm, input) ->
    match comm with
      | Common.WHO_MASTER ->
	Lwtc.log "who master" >>= fun () ->
	_get_meta store >>= fun ms ->
        let mo = extract_master_info ms in
	Llio.output_int32 oc 0l >>= fun () ->
	Llio.output_string_option oc mo >>= fun () ->
	Lwt.return false
      | Common.SET -> 
	begin
          let key = Pack.input_string input in
          let value = Pack.input_string input in
	  Lwt.catch
	    (fun () -> 
	      _set driver key value >>= fun () ->
	      Client_protocol.response_ok_unit oc)
	    (Client_protocol.handle_exception oc)
	end
      | Common.GET ->
	begin
          let allow_dirty = Pack.input_bool input in
          let key = Pack.input_string input in
          let do_get () =
            _get store key >>= fun value ->
            Client_protocol.response_rc_string oc 0l value
          in
          only_if_master allow_dirty do_get
	end 
      | Common.DELETE ->
        begin
          let key = Pack.input_string input in
	  _delete driver key >>= fun () ->
	  Client_protocol.response_ok_unit oc          
        end
      | Common.LAST_ENTRIES ->
	begin
	  Sn.input_sn ic >>= fun i ->
	  Llio.output_int32 oc 0l >>= fun () ->
	  _last_entries store i oc >>= fun () ->
	  Sn.output_sn oc (Sn.of_int (-1)) >>= fun () ->
	  Lwtc.log "end of command" >>= fun () ->
	  Lwt.return false
	end
      | Common.SEQUENCE ->
	begin
	  Lwt.catch
	    (fun () ->
	      begin
	        Llio.input_string ic >>= fun data ->
	        let probably_sequence,_ = Core.update_from data 0 in
	        let sequence = match probably_sequence with
	          | Core.SEQUENCE _ -> probably_sequence
	          | _ -> raise (Failure "should be update")
	        in
	        _sequence driver sequence >>= fun () ->
	        Client_protocol.response_ok_unit oc
	      end
	    )
	    (Client_protocol.handle_exception oc)
	end
      | Common.MULTI_GET ->
	begin
	  Llio.input_bool ic >>= fun allow_dirty ->
	  Llio.input_int ic >>= fun length ->
          let do_multi_get () = 
	    let rec loop keys i = 
	      if i = 0 then Lwt.return keys
	      else 
		begin
		  Llio.input_string ic >>= fun key ->
		  loop (key :: keys) (i-1)
		end
	    in
	    loop [] length >>= fun keys ->
            Lwt_list.map_s (fun k -> _get store k ) keys >>= fun values ->
	    Llio.output_int oc 0>>= fun () ->
	    Llio.output_int oc length >>= fun () ->
	    Lwt_list.iter_s (Llio.output_string oc) values >>= fun () ->
	    Lwt.return false
	  in
          only_if_master allow_dirty do_multi_get
	end
      | Common.RANGE ->
	_do_range S.range (Llio.output_list Llio.output_string)
      | Common.REV_RANGE_ENTRIES ->
        _do_range S.rev_range_entries Llio.output_kv_list
      | Common.RANGE_ENTRIES ->
        _do_range S.range_entries Llio.output_kv_list 
      | Common.CONFIRM ->
	begin
          Llio.input_string ic >>= fun key ->
	  Llio.input_string ic >>= fun value ->
          let do_confirm () =
            begin 
              _safe_get store key >>= fun v ->
              if v <> Some value 
              then
                _set driver key value 
              else 
                Lwt.return () 
            end
            >>= fun () -> 
            Client_protocol.response_ok_unit oc
          in 
          only_if_master false do_confirm
	end
      | Common.TEST_AND_SET ->
	Llio.input_string ic >>= fun key ->
        Llio.input_string_option ic >>= fun m_old ->
        Llio.input_string_option ic >>= fun m_new ->
        let do_test_and_set () = 
          _safe_get store key >>= fun m_val ->
	  begin
	    if m_val = m_old 
	    then
	      begin
		match m_new with
		  | None -> Lwtc.log "Test_and_set: delete" >>= fun () -> _delete driver key
		  | Some v -> Lwtc.log "Test_and_set: set" >>= fun () ->  _set driver key v
	      end 
	    else
	      begin
		Lwtc.log "Test_and_set: nothing to be done"
	      end
	  end >>= fun () ->
	  send_string_option oc m_val >>= fun () ->
	  Lwt.return false
        in
        only_if_master false do_test_and_set 
          
	(* | _ -> Client_protocol.handle_exception oc (Failure "Command not implemented (yet)") *)
	  
  let protocol me driver store (ic,oc) =   
    let rec loop () = 
      begin
	one_command me driver store (ic,oc) >>= fun stop ->
	if stop
	then Lwtc.log "end of session"
	else 
	  begin
	    Lwt_io.flush oc >>= fun () ->
	    loop ()
	  end
      end
    in
    Lwtc.log "session started" >>= fun () ->
    prologue(ic,oc) >>= fun () ->
    Lwtc.log "prologue ok" >>= fun () ->
    loop ()
      
end
