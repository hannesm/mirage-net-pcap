(*
 * Copyright (c) 2015 Mindy Preston <meetup@yomimono.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY
 * DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

module Make (K: V1_LWT.KV_RO) (T: V1_LWT.TIME) : sig
  include V1.NETWORK
    with type 'a io = 'a Lwt.t
     and type page_aligned_buffer = Io_page.t
     and type buffer = Cstruct.t
     and type macaddr = Macaddr.t

  val connect : id -> [ `Error of error | `Ok of t ] io

  val id_of_desc : ?timing:float option -> mac:Macaddr.t -> source:K.t -> read:string -> id
  (** Generate an id for use with [connect] with MAC address [mac].
      [source] is a KV_RO.t from which to attempt to read a file named [read].
      use [timing] to accelerate or decelerate playback of packets.  1.0 is
      playback at the original recorded rate.  numbers greater than 1.0 will
      delay; numbers smaller than 1.0 will speed up playback.  None gives no
      artificial delay and plays back packets as quickly as possible. *)

  val get_written : t -> Cstruct.t list
  (** return all frames written to this netif, in the order they were written.
     Each element in the list represents the contents of a call to `write`. *)
end
