//// Work with file streams in Gleam.

import file_streams/file_open_mode.{type FileOpenMode}
import file_streams/file_stream_error.{type FileStreamError}
import file_streams/internal/raw_location
import file_streams/internal/raw_read_result.{type RawReadResult}
import file_streams/internal/raw_result.{type RawResult}
import file_streams/text_encoding.{type TextEncoding, Latin1}
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

type IoDevice

/// A file stream that data can be read from and/or written to depending on the
/// modes specified when it was opened.
///
pub opaque type FileStream {
  FileStream(io_device: IoDevice, encoding: Option(TextEncoding))
}

/// Opens a new file stream that can read and/or write data from the specified
/// file. See [`FileOpenMode`](./file_open_mode.html#FileOpenMode) for all of
/// the available file modes.
///
/// For simple cases of opening a file stream prefer one of the
/// [`open_read()`](#open_read), [`open_write()`](#open_write),
/// [`open_read_text()`](#open_read_text), or
/// [`open_write_text()`](#open_write_text) helper functions to avoid needing to
/// manually specify the file mode.
///
/// Once the file stream is no longer needed it should be closed with
/// [`close()`](#close).
///
pub fn open(
  filename: String,
  modes: List(FileOpenMode),
) -> Result(FileStream, FileStreamError) {
  let is_raw = modes |> list.contains(file_open_mode.Raw)

  // Find the text encoding, if one was specified
  let encoding =
    modes
    |> list.find_map(fn(m) {
      case m {
        file_open_mode.Encoding(e) -> Ok(e)
        _ -> Error(Nil)
      }
    })
    |> option.from_result

  let encoding = case is_raw, encoding {
    // Raw mode is not allowed when specifying a text encoding, as per the
    // Erlang docs, so turn it into an explicit error
    True, Some(_) -> Error(file_stream_error.Enotsup)

    True, None -> Ok(None)
    False, _ -> Ok(encoding |> option.or(Some(text_encoding.Latin1)))
  }
  use encoding <- result.try(encoding)

  // Binary mode is forced on so the Erlang APIs return binaries rather than
  // lists
  let mode = case modes |> list.contains(file_open_mode.Binary) {
    True -> modes
    False -> [file_open_mode.Binary, ..modes]
  }

  use io_device <- result.try(do_open(filename, mode))

  Ok(FileStream(io_device, encoding))
}

@external(erlang, "file", "open")
@external(javascript, "../file_streams_ffi.mjs", "file_open")
fn do_open(
  filename: String,
  mode: List(FileOpenMode),
) -> Result(IoDevice, FileStreamError)

/// Opens a new file stream for reading from the specified file. Allows for
/// efficient reading of binary data and lines of UTF-8 text.
///
/// The modes used are:
///
/// - `Read`
/// - `ReadAhead(size: 64 * 1024)`
/// - `Raw`
///
pub fn open_read(filename: String) -> Result(FileStream, FileStreamError) {
  let modes = [
    file_open_mode.Read,
    file_open_mode.ReadAhead(64 * 1024),
    file_open_mode.Raw,
  ]

  open(filename, modes)
}

/// Opens a new file stream for reading encoded text from a file. If only
/// reading of UTF-8 lines of text is needed then prefer
/// [`open_read()`](#open_read) as it is much faster due to using `Raw` mode.
///
/// The modes used are:
///
/// - `Read`
/// - `ReadAhead(size: 64 * 1024)`
/// - `Encoding(encoding)`
///
/// The text encoding for a file stream can be changed with
/// [`set_encoding`](#set_encoding).
///
/// This function is not supported on the JavaScript target.
///
pub fn open_read_text(
  filename: String,
  encoding: TextEncoding,
) -> Result(FileStream, FileStreamError) {
  let modes = [
    file_open_mode.Read,
    file_open_mode.ReadAhead(64 * 1024),
    file_open_mode.Encoding(encoding),
  ]

  open(filename, modes)
}

/// Opens a new file stream for writing to a file. Allows for efficient writing
/// of binary data and UTF-8 text.
///
/// The modes used are:
///
/// - `Write`
/// - `DelayedWrite(size: 64 * 1024, delay: 2000)`
/// - `Raw`
///
pub fn open_write(filename: String) -> Result(FileStream, FileStreamError) {
  let modes = [
    file_open_mode.Write,
    file_open_mode.DelayedWrite(size: 64 * 1024, delay: 2000),
    file_open_mode.Raw,
  ]

  open(filename, modes)
}

/// Opens a new file stream for writing encoded text to a file. If only writing
/// of UTF-8 text is needed then prefer [`open_write()`](#open_write) as it is
/// much faster due to using `Raw` mode.
///
/// The modes used are:
///
/// - `Write`
/// - `DelayedWrite(size: 64 * 1024, delay: 2000)`
/// - `Encoding(encoding)`
///
/// The text encoding for a file stream can be changed with
/// [`set_encoding`](#set_encoding).
///
/// This function is not supported on the JavaScript target.
///
pub fn open_write_text(
  filename: String,
  encoding: TextEncoding,
) -> Result(FileStream, FileStreamError) {
  let modes = [
    file_open_mode.Write,
    file_open_mode.DelayedWrite(size: 64 * 1024, delay: 2000),
    file_open_mode.Encoding(encoding),
  ]

  open(filename, modes)
}

/// Closes an open file stream.
///
pub fn close(stream: FileStream) -> Result(Nil, FileStreamError) {
  case file_close(stream.io_device) {
    raw_result.Ok -> Ok(Nil)
    raw_result.Error(e) -> Error(e)
  }
}

@external(erlang, "file", "close")
@external(javascript, "../file_streams_ffi.mjs", "file_close")
fn file_close(io_device: IoDevice) -> RawResult

/// Changes the text encoding of a file stream from what was configured when it
/// was opened. Returns a new [`FileStream`](#FileStream) that should be used
/// for subsequent calls.
///
/// This function is not supported for file streams opened in `Raw` mode.
///
/// This function is not supported on the JavaScript target.
///
pub fn set_encoding(
  stream: FileStream,
  encoding: TextEncoding,
) -> Result(FileStream, FileStreamError) {
  use <- bool.guard(stream.encoding == None, Error(file_stream_error.Enotsup))

  let opts = [file_open_mode.Binary, file_open_mode.Encoding(encoding)]

  case io_setopts(stream.io_device, opts) {
    raw_result.Ok -> Ok(FileStream(..stream, encoding: Some(encoding)))
    raw_result.Error(e) -> Error(e)
  }
}

@external(erlang, "io", "setopts")
@external(javascript, "../file_streams_ffi.mjs", "io_setopts")
fn io_setopts(io_device: IoDevice, opts: List(FileOpenMode)) -> RawResult

/// A file stream location defined relative to the beginning of the file,
/// the end of the file, or the current position in the file stream. This type
/// is used with the [`position()`](#position) function.
///
pub type FileStreamLocation {
  /// A location relative to the beginning of the file, i.e. an absolute offset
  /// in the file stream. The offset should not be negative.
  BeginningOfFile(offset: Int)

  /// A location relative to the current position in the file stream. The offset
  /// can be either positive or negative.
  CurrentLocation(offset: Int)

  /// A location relative to the end of the file stream. The offset should not
  /// be positive.
  EndOfFile(offset: Int)
}

/// Sets the position of a file stream to the given location, where the location
/// can be relative to the beginning of the file, the end of the file, or the
/// current position in the file. On success, returns the current position in
/// the file stream as an absolute offset in bytes.
///
/// If a file stream is opened in `Append` mode then data is always written at
/// the end of the file, regardless of the current file position.
///
pub fn position(
  stream: FileStream,
  location: FileStreamLocation,
) -> Result(Int, FileStreamError) {
  let location = case location {
    BeginningOfFile(offset) -> raw_location.Bof(offset)
    CurrentLocation(offset) -> raw_location.Cur(offset)
    EndOfFile(offset) -> raw_location.Eof(offset)
  }

  file_position(stream.io_device, location)
}

@external(erlang, "file", "position")
@external(javascript, "../file_streams_ffi.mjs", "file_position")
fn file_position(
  io_device: IoDevice,
  location: raw_location.Location,
) -> Result(Int, FileStreamError)

/// Writes raw bytes to a file stream.
///
/// This function is supported when the file stream was opened in `Raw` mode or
/// it uses the default `Latin1` text encoding. If this is not the case then
/// use [`write_chars()`](#write_chars).
///
pub fn write_bytes(
  stream: FileStream,
  bytes: BitArray,
) -> Result(Nil, FileStreamError) {
  use <- bool.guard(
    stream.encoding != None && stream.encoding != Some(Latin1),
    Error(file_stream_error.Enotsup),
  )

  case file_write(stream.io_device, bytes) {
    raw_result.Ok -> Ok(Nil)
    raw_result.Error(e) -> Error(e)
  }
}

@external(erlang, "file", "write")
@external(javascript, "../file_streams_ffi.mjs", "file_write")
fn file_write(io_device: IoDevice, bytes: BitArray) -> RawResult

/// Writes characters to a file stream. This will convert the characters to the
/// text encoding specified when the file stream was opened.
///
/// For file streams opened in `Raw` mode, this function always writes UTF-8.
///
/// This function is not supported on the JavaScript target.
///
pub fn write_chars(
  stream: FileStream,
  chars: String,
) -> Result(Nil, FileStreamError) {
  case stream.encoding {
    None -> chars |> bit_array.from_string |> write_bytes(stream, _)
    Some(_) -> io_put_chars(stream.io_device, chars)
  }
}

@external(erlang, "file_streams_ffi", "io_put_chars")
@external(javascript, "../file_streams_ffi.mjs", "io_put_chars")
fn io_put_chars(
  io_device: IoDevice,
  char_data: String,
) -> Result(Nil, FileStreamError)

/// Syncs a file stream that was opened for writing. This ensures that any write
/// buffers kept by the operating system (not by the Erlang runtime system) are
/// written to disk.
///
/// When a file stream is opened with delayed writes enabled to improve
/// performance, syncing can return an error related to flushing recently
/// written data to the underlying device.
///
pub fn sync(stream: FileStream) -> Result(Nil, FileStreamError) {
  case file_sync(stream.io_device) {
    raw_result.Ok -> Ok(Nil)
    raw_result.Error(e) -> Error(e)
  }
}

@external(erlang, "file", "sync")
@external(javascript, "../file_streams_ffi.mjs", "file_sync")
fn file_sync(io_device: IoDevice) -> RawResult

/// Reads bytes from a file stream. The returned number of bytes may be fewer
/// than the number that was requested if the end of the file stream was
/// reached.
///
/// If the end of the file stream is encountered before any bytes can be read
/// then `Error(Eof)` is returned.
///
/// This function is supported when the file stream was opened in `Raw` mode or
/// it uses the default `Latin1` text encoding. If this is not the case then
/// use [`read_chars()`](#read_chars) or [`read_line()`](#read_line).
///
pub fn read_bytes(
  stream: FileStream,
  byte_count: Int,
) -> Result(BitArray, FileStreamError) {
  use <- bool.guard(
    stream.encoding != None && stream.encoding != Some(Latin1),
    Error(file_stream_error.Enotsup),
  )

  case file_read(stream.io_device, byte_count) {
    raw_read_result.Ok(bytes) -> Ok(bytes)
    raw_read_result.Eof -> Error(file_stream_error.Eof)
    raw_read_result.Error(e) -> Error(e)
  }
}

@external(erlang, "file", "read")
@external(javascript, "../file_streams_ffi.mjs", "file_read")
fn file_read(io_device: IoDevice, byte_count: Int) -> RawReadResult(BitArray)

/// Reads the requested number of bytes from a file stream. If the requested
/// number of bytes can't be read prior to reaching the end of the file stream
/// then `Error(Eof)` is returned.
///
/// This function is supported when the file stream was opened in `Raw` mode or
/// it uses the default `Latin1` text encoding. If this is not the case then use
/// [`read_chars()`](#read_chars) or [`read_line()`](#read_line) should be used
/// instead.
///
pub fn read_bytes_exact(
  stream: FileStream,
  byte_count: Int,
) -> Result(BitArray, FileStreamError) {
  case read_bytes(stream, byte_count) {
    Ok(bytes) ->
      case bit_array.byte_size(bytes) == byte_count {
        True -> Ok(bytes)
        False -> Error(file_stream_error.Eof)
      }

    error -> error
  }
}

/// Reads all remaining bytes from a file stream. If no more data is available
/// in the file stream then this function will return an empty bit array. It
/// never returns `Error(Eof)`.
///
/// This function is supported when the file stream was opened in `Raw` mode or
/// it uses the default `Latin1` text encoding. If this is not the case then use
/// [`read_chars()`](#read_chars) or [`read_line()`](#read_line) should be used
/// instead.
///
pub fn read_remaining_bytes(
  stream: FileStream,
) -> Result(BitArray, FileStreamError) {
  do_read_remaining_bytes(stream, [])
}

fn do_read_remaining_bytes(
  stream: FileStream,
  acc: List(BitArray),
) -> Result(BitArray, FileStreamError) {
  case read_bytes(stream, 64 * 1024) {
    Ok(bytes) -> do_read_remaining_bytes(stream, [bytes, ..acc])

    Error(file_stream_error.Eof) ->
      acc
      |> list.reverse
      |> bit_array.concat
      |> Ok

    Error(e) -> Error(e)
  }
}

/// Reads the next line of text from a file stream. The returned string
/// will include the newline `\n` character. If the stream contains a Windows
/// newline `\r\n` then only the `\n` will be returned.
///
/// This function always reads UTF-8 for file streams opened in `Raw` mode.
/// Otherwise, it uses the text encoding specified when the file was opened.
///
/// This function is not supported on the JavaScript target.
///
pub fn read_line(stream: FileStream) -> Result(String, FileStreamError) {
  case stream.encoding {
    None ->
      case file_read_line(stream.io_device) {
        raw_read_result.Ok(data) ->
          data
          |> bit_array.to_string
          |> result.replace_error(file_stream_error.InvalidUnicode)

        raw_read_result.Eof -> Error(file_stream_error.Eof)
        raw_read_result.Error(e) -> Error(e)
      }

    Some(_) ->
      case io_get_line(stream.io_device) {
        raw_read_result.Ok(data) -> Ok(data)
        raw_read_result.Eof -> Error(file_stream_error.Eof)
        raw_read_result.Error(e) -> Error(e)
      }
  }
}

@external(erlang, "file_streams_ffi", "io_get_line")
@external(javascript, "../file_streams_ffi.mjs", "io_get_line")
fn io_get_line(io_device: IoDevice) -> RawReadResult(String)

@external(erlang, "file", "read_line")
@external(javascript, "../file_streams_ffi.mjs", "file_read_line")
fn file_read_line(io_device: IoDevice) -> RawReadResult(BitArray)

/// Reads the next `count` characters from a file stream. The returned number of
/// characters may be fewer than the number that was requested if the end of the
/// stream is reached.
///
/// This function is not supported for file streams opened in `Raw` mode. Use
/// the [`read_line()`](#read_line) function instead.
///
/// This function is not supported on the JavaScript target.
///
pub fn read_chars(
  stream: FileStream,
  count: Int,
) -> Result(String, FileStreamError) {
  case stream.encoding {
    Some(_) ->
      case io_get_chars(stream.io_device, count) {
        raw_read_result.Ok(data) -> Ok(data)
        raw_read_result.Eof -> Error(file_stream_error.Eof)
        raw_read_result.Error(e) -> Error(e)
      }

    None -> Error(file_stream_error.Enotsup)
  }
}

@external(erlang, "file_streams_ffi", "io_get_chars")
@external(javascript, "../file_streams_ffi.mjs", "io_get_chars")
fn io_get_chars(io_device: IoDevice, count: Int) -> RawReadResult(String)

/// Reads an 8-bit signed integer from a file stream.
///
pub fn read_int8(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 1))

  let assert <<v:signed-size(8)>> = bits
  v
}

/// Reads an 8-bit unsigned integer from a file stream.
///
pub fn read_uint8(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 1))

  let assert <<v:unsigned-size(8)>> = bits
  v
}

/// Reads a little-endian 16-bit signed integer from a file stream.
///
pub fn read_int16_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 2))

  let assert <<v:little-signed-size(16)>> = bits
  v
}

/// Reads a big-endian 16-bit signed integer from a file stream.
///
pub fn read_int16_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 2))

  let assert <<v:big-signed-size(16)>> = bits
  v
}

/// Reads a little-endian 16-bit unsigned integer from a file stream.
///
pub fn read_uint16_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 2))

  let assert <<v:little-unsigned-size(16)>> = bits
  v
}

/// Reads a big-endian 16-bit unsigned integer from a file stream.
///
pub fn read_uint16_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 2))

  let assert <<v:big-unsigned-size(16)>> = bits
  v
}

/// Reads a little-endian 32-bit signed integer from a file stream.
///
pub fn read_int32_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:little-signed-size(32)>> = bits
  v
}

/// Reads a big-endian 32-bit signed integer from a file stream.
///
pub fn read_int32_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:big-signed-size(32)>> = bits
  v
}

/// Reads a little-endian 32-bit unsigned integer from a file stream.
///
pub fn read_uint32_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:little-unsigned-size(32)>> = bits
  v
}

/// Reads a big-endian 32-bit unsigned integer from a file stream.
///
pub fn read_uint32_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:big-unsigned-size(32)>> = bits
  v
}

/// Reads a little-endian 64-bit signed integer from a file stream.
///
pub fn read_int64_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:little-signed-size(64)>> = bits
  v
}

/// Reads a big-endian 64-bit signed integer from a file stream.
///
pub fn read_int64_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:big-signed-size(64)>> = bits
  v
}

/// Reads a little-endian 64-bit unsigned integer from a file stream.
///
pub fn read_uint64_le(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:little-unsigned-size(64)>> = bits
  v
}

/// Reads a big-endian 64-bit unsigned integer from a file stream.
///
pub fn read_uint64_be(stream: FileStream) -> Result(Int, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:big-unsigned-size(64)>> = bits
  v
}

/// Reads a little-endian 32-bit float from a file stream.
///
pub fn read_float32_le(stream: FileStream) -> Result(Float, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:little-float-size(32)>> = bits
  v
}

/// Reads a big-endian 32-bit float from a file stream.
///
pub fn read_float32_be(stream: FileStream) -> Result(Float, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 4))

  let assert <<v:big-float-size(32)>> = bits
  v
}

/// Reads a little-endian 64-bit float from a file stream.
///
pub fn read_float64_le(stream: FileStream) -> Result(Float, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:little-float-size(64)>> = bits
  v
}

/// Reads a big-endian 64-bit float from a file stream.
///
pub fn read_float64_be(stream: FileStream) -> Result(Float, FileStreamError) {
  use bits <- result.map(read_bytes_exact(stream, 8))

  let assert <<v:big-float-size(64)>> = bits
  v
}

/// Reads the specified type the requested number of times from a file stream,
/// e.g. two little-endian 32-bit integers, or four big-endian 64-bit floats,
/// and returns the values in a list.
///
/// ## Examples
///
/// ```gleam
/// read_list(stream, read_int32_le, 2)
/// |> Ok([1, 2])
///
/// read_list(stream, read_float64_be, 4)
/// |> Ok([1.0, 2.0])
/// ```
///
pub fn read_list(
  stream: FileStream,
  item_read_fn: fn(FileStream) -> Result(a, FileStreamError),
  item_count: Int,
) -> Result(List(a), FileStreamError) {
  do_read_list(stream, item_read_fn, item_count, [])
  |> result.map(list.reverse)
}

fn do_read_list(
  stream: FileStream,
  item_read_fn: fn(FileStream) -> Result(a, FileStreamError),
  item_count: Int,
  acc: List(a),
) -> Result(List(a), FileStreamError) {
  case item_count {
    0 -> Ok(acc)
    _ ->
      case item_read_fn(stream) {
        Ok(item) ->
          do_read_list(stream, item_read_fn, item_count - 1, [item, ..acc])
        Error(e) -> Error(e)
      }
  }
}
