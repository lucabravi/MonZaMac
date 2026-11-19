// The same decoder as a C library for tools/za/prompt_textures.py (the zaprompts helper): src_len bytes of an Oodle
// stream into dst_len bytes; returns the bytes written (dst_len when whole), or -1.
#[no_mangle]
pub unsafe extern "C" fn ooz_decompress(src: *const u8, src_len: usize, dst: *mut u8, dst_len: usize) -> i64 {
    if src.is_null() || dst.is_null() || dst_len == 0 { return -1; }
    let (src, dst) = (std::slice::from_raw_parts(src, src_len), std::slice::from_raw_parts_mut(dst, dst_len));
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| oozextract::Extractor::new().read_from_slice(src, dst))) {
        Ok(Ok(n)) => n as i64,
        _ => -1,
    }
}
