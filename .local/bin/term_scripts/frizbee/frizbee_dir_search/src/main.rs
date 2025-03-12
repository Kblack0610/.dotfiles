use frizbee::*;
fn main() {
    let needle = "pri";
    let haystacks = ["print", "println", "prelude", "println!"];

    let matches = match_list(needle, &haystacks, Options::default());
    println!("{matches:?}");
}
