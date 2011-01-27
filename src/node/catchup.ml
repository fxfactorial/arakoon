(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
*)

open Lwt
open Node_cfg
open Remote_nodestream
open Tlogcollection
open Log_extra
open Update
open Store

type store_tlc_cmp =
  | Store_n_behind
  | Store_1_behind
  | Store_tlc_equal
  | Store_ahead

let compare_store_tlc store tlc =
  store # consensus_i () >>= fun m_store_i ->
  tlc # get_last_i () >>= fun tlc_i ->
  match m_store_i with
  | None ->
    if tlc_i = ( Sn.succ Sn.start )
    then Lwt.return Store_1_behind
    else Lwt.return Store_n_behind
  | Some store_i when store_i = tlc_i -> Lwt.return Store_tlc_equal
  | Some store_i when store_i > tlc_i -> Lwt.return Store_ahead
  | Some store_i ->
    if store_i = (Sn.pred tlc_i)
    then Lwt.return Store_1_behind
    else Lwt.return Store_n_behind

let catchup_tlog me other_configs (current_i: Sn.t) mr_name
    (tlog_coll:Tlogcollection.tlog_collection)=
  Lwt_log.debug_f "catchup_tlog %s" (Sn.string_of current_i) >>= fun () ->
  let mr_cfg = List.find (fun cfg -> Node_cfg.node_name cfg = mr_name)
    other_configs in
  let mr_address = Node_cfg.client_address mr_cfg
  and mr_name = Node_cfg.node_name mr_cfg in
  Lwt_log.debug_f "getting last_entries from %s" mr_name >>= fun () ->
  
  let copy_tlog connection =
    let client = new remote_nodestream connection in

    let f (i,update) =
      Lwt_log.debug_f "%s:%s => tlog" 
	(Sn.string_of i) (Update.string_of update) >>= fun () ->
      tlog_coll # log_update i update >>=
	fun _ -> 
      Lwt.return ()
    in
    client # iterate current_i f 
  in
  Lwt.catch
    (fun () ->
      Lwt_io.with_connection mr_address copy_tlog >>= fun () ->
      Lwt_log.debug_f "catchup_tlog completed" 
    )
    (fun exn -> Lwt_log.warning ~exn "catchup_tlog failed") 
  >>= fun () ->
  tlog_coll # get_last_i () >>= fun tlc_i ->
  let fsm_i = Sn.succ ( tlc_i ) in 
  Lwt.return fsm_i

let catchup_store me store (tlog_coll:tlog_collection) (future_i:Sn.t) =
  Lwt_log.info "replaying log to store"
  >>= fun () ->
  store # consensus_i () >>= fun store_i ->
  let start_i =
    match store_i with
      | None -> Sn.start
      | Some i -> Sn.succ i
  in
  if Sn.compare start_i future_i > 0 
  then 
    let msg = Printf.sprintf "Store counter (%s) is ahead of tlog counter (%s). Aborting." 
      (Sn.string_of start_i) (Sn.string_of future_i) in
    Lwt.fail (Failure msg)
  else
  begin 
  Lwt_log.debug_f "will replay starting from %s into store, until we're @ %s" 
    (Sn.string_of start_i) (Sn.string_of future_i)
  >>= fun () ->
  let acc = ref None in
  let f (i,update) =
    match !acc with
      | None ->
	let () = acc := Some(i,update) in
	Lwt_log.debug_f "update %s has no previous" (Sn.string_of i) >>= fun () ->
	Lwt.return ()
      | Some (pi,pu) ->
	if pi < i then
	  begin
	    Lwt_log.debug_f "%s => store" (Sn.string_of pi) >>= fun () ->
	    Store.safe_insert_update store pi pu >>= fun _ ->
	    let () = acc := Some(i,update) in
	    Lwt.return ()
	  end
	else
	  begin
	    Lwt_log.debug_f "%s => skip" (Sn.string_of pi) >>= fun () ->
	    let () = acc := Some(i,update) in
	    Lwt.return ()
	  end
  in
  tlog_coll # iterate start_i future_i f >>= fun () ->
  store # consensus_i () >>= fun store_i' ->
  Lwt_log.info_f "catchup_store completed, store is @ %s" 
    ( option_to_string Sn.string_of store_i')
  >>= fun () ->
  (* TODO: straighten interface *)
  let vo = match !acc with
      | None -> None
      | Some (i,u) -> let v = Update.make_update_value u in Some v
  in
  Lwt.return (future_i, vo)
  end

let catchup me other_configs (db,tlog_coll) current_i mr_name (future_n,future_i) =
  Lwt_log.info_f "CATCHUP start: I'm @ %s and %s is more recent (%s,%s)"
    (Sn.string_of current_i) mr_name (Sn.string_of future_n) 
    (Sn.string_of future_i)
  >>= fun () ->
  catchup_tlog me other_configs current_i mr_name tlog_coll>>= fun future_i' ->
  catchup_store me db tlog_coll future_i' >>= fun (end_i,vo) ->
  Lwt_log.info_f "CATCHUP end" >>= fun () ->
  Lwt.return (future_n, end_i,vo)


let verify_n_catchup_store me (store, tlog_coll, ti_o) ~current_i forced_master =
  let io_s = Log_extra.option_to_string Sn.string_of  in
  Lwt_log.info_f "verify_n_catchup_store; ti_o=%s current_i=%s"
    (io_s ti_o) (Sn.string_of current_i) >>= fun () ->
  store # consensus_i () >>= fun si_o ->
  match ti_o, si_o with
    | None, None -> Lwt.return (0L,None)
    | Some 0L, None -> Lwt.return (0L,None)
    | Some i, Some j when i = Sn.succ j -> (* tlog 1 ahead of store *)
      tlog_coll # get_last_update i >>= fun uo ->
      let vo = match uo with
	| None -> None
	| Some u -> let v = Update.make_update_value u in Some v
      in
      Lwt.return (i,vo)
    | Some i, Some j when i = j -> Lwt.return ((Sn.succ j),None)
    | Some i, Some j when i > j -> 
      begin
	catchup_store me store tlog_coll current_i >>= fun (end_i, vo) ->
	Lwt.return (end_i,vo)
      end
    | Some i, None ->
      begin
	catchup_store me store tlog_coll current_i >>= fun (end_i, vo) ->
	Lwt.return (end_i,vo)
      end
    | _,_ -> 
      let msg = Printf.sprintf 
	"ti_o:%s, si_o:%s should not happen: tlogs have been removed?" 
	(io_s ti_o) (io_s si_o) 
      in
      Lwt.fail (Failure msg)

