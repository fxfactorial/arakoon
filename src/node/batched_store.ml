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

open Store
open Lwt

module StringMap = Map.Make(String)

module type Extended_simple_store =
sig
  include Simple_store
  val _tranbegin : t -> transaction
  val _tranfinish : t -> unit
end

module Batched_store = functor (S : Extended_simple_store) ->
struct
  type t = {
    s : S.t;
    mutable _cache : string option StringMap.t;
    mutable _current_tx_cache : string option StringMap.t;

    _tx_lock : Lwt_mutex.t;
    mutable _tx : transaction option;

    mutable _s_tx : transaction option;

    mutable _counter : int;
  }

  let make_store b s =
    S.make_store b s >>= fun s -> Lwt.return {
      s;
      _cache = StringMap.empty;
      _current_tx_cache = StringMap.empty;

      _tx_lock = Lwt_mutex.create ();
      _tx = None;

      _s_tx = None;

      _counter = 0;
    }

  let _apply_vo_to_store s tx k vo =
    match vo with
      | Some v -> S.set s tx k v
      | None ->
          if S.exists s k
          then
            S.delete s tx k

  let _apply_changes s tx m =
    StringMap.iter
      (fun k vo -> _apply_vo_to_store s tx k vo)
      m

  let _apply_value s k vo =
    match s._s_tx with
      | None    -> s._current_tx_cache <- StringMap.add k vo s._current_tx_cache
      | Some tx -> _apply_vo_to_store s.s tx k vo

  let _finalize f g =
    try
      f ();
      g ();
    with exn -> g (); raise exn

  let _sync_cache_to_store s =
    if not (StringMap.is_empty s._cache)
    then
      begin
        let tx = S._tranbegin s.s in
        _apply_changes s.s tx s._cache;
        _finalize
          (fun () ->
            S._tranfinish s.s)
          (fun () ->
            s._cache <- StringMap.empty;
            s._s_tx <- None;
            s._counter <- 0)
      end

  let _sync_and_start_transaction_if_needed s =
    if s._tx = None
    then
      _sync_cache_to_store s
    else
      (* we're asked to sync from within a Batched_store transaction *)
      if s._s_tx = None (* start a S transaction should none be initiated so far *)
      then
        begin
          _sync_cache_to_store s;
          let tx = S._tranbegin s.s in
          s._s_tx <- Some tx;
          _apply_changes s.s tx s._current_tx_cache;
          s._current_tx_cache <- StringMap.empty
        end

  let with_transaction s f =
    Lwt_mutex.with_lock s._tx_lock (fun () ->
      let tx = new transaction in
      s._tx <- Some tx;
      Lwt.finalize
        (fun () ->
          f tx >>= fun r ->

          (* transaction succeeded, let's apply the changes accumulated in _current_tx_cache *)
          s._cache <- StringMap.fold (fun k vo acc -> StringMap.add k vo acc) s._current_tx_cache s._cache;

          (* TODO a more intelligent check to see _push_to_store if desired *)
          s._counter <- s._counter + 1;
          if s._counter = 200
          then _sync_cache_to_store s;

          Lwt.return r)
        (fun () ->
          s._tx <- None;
          s._current_tx_cache <- StringMap.empty;
          Lwt.return ()))


  let exists s k =
    if StringMap.mem k s._current_tx_cache
    then
      match StringMap.find k s._current_tx_cache with
        | None -> false
        | Some _ -> true
    else if StringMap.mem k s._cache
    then
      match StringMap.find k s._cache with
        | None -> false
        | Some _ -> true
    else
      S.exists s.s k

  let get s k =
    if StringMap.mem k s._current_tx_cache
    then
      match StringMap.find k s._current_tx_cache with
        | None -> raise Not_found
        | Some v -> v
    else if StringMap.mem k s._cache
    then
      match StringMap.find k s._cache with
        | None -> raise Not_found
        | Some v -> v
    else
      S.get s.s k

  let set s t k v =
    _apply_value s k (Some v)

  let delete s t k =
    if exists s k
    then
      _apply_value s k None
    else
      raise Not_found

  let range s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.range s.s prefix first finc last linc max

  let range_entries s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.range_entries s.s prefix first finc last linc max

  let rev_range_entries s prefix first finc last linc max =
    _sync_and_start_transaction_if_needed s;
    S.range_entries s.s prefix first finc last linc max

  let prefix_keys s prefix max =
    _sync_and_start_transaction_if_needed s;
    S.prefix_keys s.s prefix max

  let delete_prefix s t prefix =
    _sync_and_start_transaction_if_needed s;
    S.delete_prefix s.s t prefix

  let close s =
    _sync_and_start_transaction_if_needed s;
    S.close s.s

  let reopen s =
    _sync_and_start_transaction_if_needed s;
    S.reopen s.s

  let get_location s =
    S.get_location s.s

  let relocate s =
    _sync_and_start_transaction_if_needed s;
    S.relocate s.s

  let get_key_count s =
    _sync_and_start_transaction_if_needed s;
    S.get_key_count s.s

  let optimize s =
    _sync_and_start_transaction_if_needed s;
    S.optimize s.s

  let defrag s =
    _sync_and_start_transaction_if_needed s;
    S.defrag s.s

  let copy_store s =
    _sync_and_start_transaction_if_needed s;
    S.copy_store s.s

  let copy_store2 =
    S.copy_store2

  let get_fringe s =
    _sync_and_start_transaction_if_needed s;
    S.get_fringe s.s
end

module Local_store = Batched_store(Local_store)

