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

module Make (K: V1_LWT.KV_RO) (T: V1_LWT.TIME) = struct
  type 'a io = 'a Lwt.t
  type page_aligned_buffer = Io_page.t
  type buffer = Cstruct.t
  type macaddr = Macaddr.t
  type error = [ `Unimplemented
               | `Disconnected
               | `Unknown of string ]

  type read_result = [
      `Ok of page_aligned_buffer list
    | `Error of K.error
  ]

  type stats = {
    mutable rx_bytes : int64;
    mutable rx_pkts : int32;
    mutable tx_bytes : int64;
    mutable tx_pkts : int32;
  }

  type id = {
    timing : float option;
    file : string;
    source : K.t;
    mac : Macaddr.t;
  }

  type t = {
    source : id; (* should really be something like an fd *)
    seek : int;
    last_read : float option;
    stats : stats;
    reader : (module Pcap.HDR);
    header : Cstruct.t ;
    written : Cstruct.t list ref;
  }

  let reset_stats_counters t = ()
  let get_stats_counters t = t.stats
  let empty_stats_counter = {
    rx_bytes = 0L;
    rx_pkts = 0l;
    tx_bytes = 0L;
    tx_pkts = 0l;
  }

  let string_of_t t =
    let explicate k = string_of_int k in
    Printf.sprintf "source is file %s; we're at position %s" t.source.file
      (explicate t.seek)

  let mac t = t.source.mac

  let id_of_desc ?(timing = None) ~mac ~source ~read =
    { timing; source; file = read; mac }

  let id t = t.source
  let connect (i : id) =
    let open Lwt in
    K.read i.source i.file 0 (Pcap.sizeof_pcap_header) >>=
    function
    | `Error _ -> Lwt.return (`Error (`Unknown "file could not be read") )
    | `Ok bufs ->
      match bufs with
      | [] -> Lwt.return (`Error (`Unknown "empty file"))
      | hd :: _ ->
        (* hopefully we have a pcap header in bufs *)
        match Pcap.detect hd with
        | None -> Lwt.return (`Error (`Unknown "file could not be parsed"))
        | Some reader ->
          Lwt.return (`Ok {
              source = i;
              seek = Pcap.sizeof_pcap_header;
              last_read = None;
              stats = empty_stats_counter;
              header = hd ;
              reader;
              written = ref [];
            })

  let disconnect t =
    Lwt.return_unit

  let writev t bufs = t.written := t.!written @ bufs; Lwt.return_unit
  let write t buf = writev t [buf]

  let get_written t = t.!written

  let advance_seek t seek = { t with seek = (t.seek + seek); }

  let set_last_read t last_read =
    { t with last_read = last_read; }

  (* merge bufs into one big cstruct. *)
  let combine_cstructs l =
    match l with
    | hd :: [] -> hd
    | _ ->
      let consolidated = Cstruct.create (Cstruct.lenv l) in
      let fill seek buf =
        Cstruct.blit buf 0 consolidated seek (Cstruct.len buf);
        seek + (Cstruct.len buf)
      in
      ignore (List.fold_left fill 0 l);
      consolidated

  let rec listen t cb =
    let open Lwt in
    let module R = (val t.reader : Pcap.HDR) in
    let stuff x = match R.get_pcap_header_network t.header with
      | 1l -> x
      | 0l -> match Cstruct.LE.get_uint32 x 0 with
        | 2l ->
          let hdr = Cstruct.create 14 in
          Cstruct.BE.set_uint16 hdr 12 0x800 ;
          combine_cstructs [hdr ; Cstruct.shift x 4]
    in
    let read_wrapper (i : id) seek how_many =
      K.read i.source i.file seek how_many >>= function
      | `Ok [] -> Lwt.return None
      | `Ok (buf :: []) -> Lwt.return (Some (Cstruct.sub buf 0 how_many))
      | `Ok bufs -> Lwt.return (Some (combine_cstructs bufs))
      | `Error _ -> raise (Invalid_argument "Read failed")
    in
    let next_packet t =
      read_wrapper t.source t.seek Pcap.sizeof_pcap_packet >>=
      function
      | None -> Lwt.return None
      | Some packet_header ->
        let t = advance_seek t Pcap.sizeof_pcap_packet in
        (* try to read packet body *)
        let packet_size = Int32.to_int (R.get_pcap_packet_incl_len
                                          packet_header) in
        let packet_secs = R.get_pcap_packet_ts_sec packet_header in
        let packet_usecs = R.get_pcap_packet_ts_usec packet_header in
        let (t, delay) =
          let pack (secs, usecs) =
            let secs_of_usecs = (1.0 /. 1000000.0) in
            (float_of_int (Int32.to_int secs)) +.
            ((float_of_int (Int32.to_int usecs)) *. secs_of_usecs)
          in
          let this_time = pack (packet_secs, packet_usecs) in
          match t.last_read with
          | None -> (set_last_read t (Some this_time), 0.0)
          | Some last_time ->
            match t.source.timing with
            | None -> (set_last_read t (Some this_time), 0.0)
            | Some timing ->
              (set_last_read t (Some this_time)), ((this_time -. last_time) *.
                                                   timing)
        in
        read_wrapper t.source t.seek packet_size >>= function
        | None -> Lwt.return None
        | Some packet_body ->
          let t = advance_seek t (packet_size) in
          let packet = stuff packet_body in
          return (Some (t, delay, packet))
    in
    next_packet t >>= function
    | None -> Lwt.return_unit
    | Some (next_t, delay, packet) ->
      T.sleep delay >>= fun () ->
      cb packet >>= fun () ->
      listen next_t cb

end
