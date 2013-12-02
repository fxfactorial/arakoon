(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2013 Incubaid BVBA

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

module Mode = struct
  type t = NotQuiesced
         | ReadOnly
         | Writable

  let to_string = function
    | NotQuiesced -> "NotQuiesced"
    | ReadOnly -> "ReadOnly"
    | Writable -> "Writable"

  let is_quiesced = function
    | NotQuiesced -> false
    | ReadOnly | Writable -> true
end

module Result = struct
  type t = OK
         | FailMaster
         | Fail

  let to_string = function
    | OK -> "OK"
    | FailMaster -> "FailMaster"
    | Fail -> "Fail"
end
