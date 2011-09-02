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

open Update
open Interval
open Routing
open Common
open Lwt

class type nodestream = object
  method iterate: 
    Sn.t -> (Sn.t * Update.t -> unit Lwt.t) ->
    Tlogcollection.tlog_collection ->
    head_saved_cb:(string -> unit Lwt.t) -> unit Lwt.t
      
  method collapse: int -> unit Lwt.t

  method set_routing: Routing.t -> unit Lwt.t
  method get_routing: unit -> Routing.t Lwt.t
  
  method get_db: string -> unit Lwt.t

  method get_tail: string -> ((string * string) list) Lwt.t

end

class remote_nodestream ((ic,oc) as conn) = object(self :# nodestream)
  method iterate (i:Sn.t) (f: Sn.t * Update.t -> unit Lwt.t)  
    (tlog_coll: Tlogcollection.tlog_collection) 
    ~head_saved_cb
    =
    let outgoing buf =
      command_to buf LAST_ENTRIES;
      Sn.sn_to buf i
    in
    let incoming ic =
      let save_head () = tlog_coll # save_head ic in
      let last_seen = ref None in
      let rec loop_entries () =
	Sn.input_sn ic >>= fun i2 ->
	begin
	  if i2 = (-1L) 
	  then
	    begin
	    Lwt_log.info_f "remote_nodestream :: iterate (i = %s) last_seen = %s" 
	      (Sn.string_of i)
	      (Log_extra.option_to_string Sn.string_of !last_seen)
	    end
	  else
	    begin
	      last_seen := Some i2;
	      Llio.input_int32 ic >>= fun chksum ->
	      Llio.input_string ic >>= fun entry ->	      
	      let update,_ = Update.from_buffer entry 0 in
	      f (i2, update) >>= fun () ->
              loop_entries ()
	    end
	end
      in 
      Llio.input_int ic >>= function
	| 1 -> loop_entries ()
	| 2 -> 
	  begin 
	    save_head () >>= fun () -> 
	    let hf_name = tlog_coll # get_head_filename () in
	    head_saved_cb hf_name >>= fun () ->
	    loop_entries ()
	  end
	| x -> Llio.lwt_failfmt "don't know what %i means" x
    in
    request  oc outgoing >>= fun () ->
    response ic incoming  


  method collapse n =
    let outgoing buf =
      command_to buf COLLAPSE_TLOGS;
      Llio.int_to buf n
    in
    let incoming ic =
      Llio.input_int ic >>= fun collapse_count ->
      let rec loop i =
      	if i = 0 
        then Lwt.return ()
	else 
      	  begin
            Llio.input_int ic >>= function
              | 0 ->
	        Llio.input_int64 ic >>= fun took ->
	        Lwt_log.debug_f "collapsing one file took %Li" took >>= fun () ->
	        loop (i-1)
              | e ->
                Llio.input_string ic >>= fun msg ->
                Llio.lwt_failfmt "%s (EC: %d)" msg e
	  end
      in
      loop collapse_count
    in
    request  oc outgoing >>= fun () ->
    response ic incoming


  method set_interval iv =
    let outgoing buf = 
      command_to buf SET_INTERVAL;
      Interval.interval_to buf iv
    in
    request  oc outgoing >>= fun () ->
    response ic nothing

  method get_routing () =
    let outgoing buf = command_to buf GET_ROUTING
    in
    request  oc outgoing >>= fun () ->
    response ic Routing.input_routing

  method set_routing r = 
    let outgoing buf = 
      command_to buf SET_ROUTING;
      let b' = Buffer.create 100 in
      Routing.routing_to b' r;
      let size = Buffer.length b' in
      Llio.int_to buf size;
      Buffer.add_buffer buf b'
    in
    request  oc outgoing >>= fun  () ->
    response ic nothing
    
  method get_db db_location =
    
    let outgoing buf =
      command_to buf GET_DB;
    in
    let incoming ic =
      Llio.input_int64 ic >>= fun length -> 
      Lwt_io.with_file ~mode:Lwt_io.output db_location (fun oc -> Llio.copy_stream ~length ~ic ~oc)
    in
    request  oc outgoing >>= fun () ->
    response ic incoming

  method get_tail (lower:string) = Common.get_tail conn lower
end

let make_remote_nodestream cluster connection = 
  prologue cluster connection >>= fun () ->
  let rns = new remote_nodestream connection in
  let a = (rns :> nodestream) in
  Lwt.return a
  
 
