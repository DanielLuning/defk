// The NIF a careful Elixir developer would write for 1BRC: one function that
// aggregates a newline-aligned chunk into min/max/sum/count per station, with
// the temperature parsed as an integer x10, a std HashMap<&[u8], Stats> keyed
// by borrowed slices of the input (no per-row allocation), and one binary per
// distinct station in the result.
use rustler::{Binary, Env, NewBinary, Term};
use std::collections::HashMap;

#[derive(Clone, Copy)]
struct Stats {
    min: i64,
    max: i64,
    sum: i64,
    count: i64,
}

fn run<'a>(env: Env<'a>, chunk: Binary<'a>) -> Vec<(Binary<'a>, i64, i64, i64, i64)> {
    let data = chunk.as_slice();
    let mut map: HashMap<&[u8], Stats> = HashMap::with_capacity(1024);
    let mut pos = 0;
    let n = data.len();
    while pos < n {
        // name up to ';'
        let semi = pos + data[pos..].iter().position(|&b| b == b';').expect("line without ;");
        let name = &data[pos..semi];
        // temperature: [-]d[d].d, integer tenths
        let mut i = semi + 1;
        let neg = data[i] == b'-';
        if neg {
            i += 1;
        }
        let mut t: i64 = 0;
        while data[i] != b'\n' {
            if data[i] != b'.' {
                t = t * 10 + (data[i] - b'0') as i64;
            }
            i += 1;
        }
        if neg {
            t = -t;
        }
        pos = i + 1;
        map.entry(name)
            .and_modify(|s| {
                s.min = s.min.min(t);
                s.max = s.max.max(t);
                s.sum += t;
                s.count += 1;
            })
            .or_insert(Stats { min: t, max: t, sum: t, count: 1 });
    }
    map.into_iter()
        .map(|(name, s)| {
            let mut nb = NewBinary::new(env, name.len());
            nb.as_mut_slice().copy_from_slice(name);
            (Binary::from(nb), s.min, s.max, s.sum, s.count)
        })
        .collect()
}

#[rustler::nif]
fn aggregate<'a>(env: Env<'a>, chunk: Binary<'a>) -> Vec<(Binary<'a>, i64, i64, i64, i64)> {
    run(env, chunk)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn aggregate_dirty<'a>(env: Env<'a>, chunk: Binary<'a>) -> Vec<(Binary<'a>, i64, i64, i64, i64)> {
    run(env, chunk)
}

fn load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.OneBrc.Nif", load = load);
