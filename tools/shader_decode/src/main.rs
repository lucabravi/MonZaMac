// Private bounded subprocess: an eight-byte LE output length, then compressed bytes.
use std::{env, fs, io, path::Path};
const LIMIT: u64 = 128 << 20;
fn decode(input: &Path, output: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let len = fs::metadata(input)?.len();
    if !(9..=LIMIT + 8).contains(&len) { return Err("input length outside limit".into()); }
    let bytes = fs::read(input)?;
    let size = u64::from_le_bytes(bytes[..8].try_into()?);
    if size == 0 || size > LIMIT { return Err("output length outside limit".into()); }
    let mut out = vec![0u8; size as usize];
    let actual = oozextract::Extractor::new().read_from_slice(&bytes[8..], &mut out)?;
    if actual != out.len() { return Err("decoded length mismatch".into()); }
    // The caller supplies a newly created private temporary directory.
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(output)?;
    io::Write::write_all(&mut file, &out)?;
    Ok(())
}
fn main() {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 { eprintln!("usage: monzamac-shader-decode input output"); std::process::exit(2); }
    if let Err(e) = decode(Path::new(&args[1]), Path::new(&args[2])) {
        eprintln!("shader decode failed: {e}"); std::process::exit(1);
    }
}
