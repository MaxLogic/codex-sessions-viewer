//! Behavior that must match the Dart viewer byte for byte.
//!
//! The viewer stores what its Dart parser produces. Rows written here have to
//! compare equal to those rows, so string lengths count UTF-16 code units,
//! whitespace follows Dart's `String.trim` and JavaScript `\s`, timestamps
//! follow `DateTime.tryParse`/`toIso8601String`, and JSON text follows
//! `jsonEncode`.

use std::cmp::Ordering;
use std::fmt::Write as _;

use serde_json::Value;
use sha2::{Digest, Sha256};

/// Whitespace removed by Dart's `String.trim`: Unicode `White_Space` plus BOM.
pub fn is_dart_trim_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{09}'..='\u{0D}'
            | '\u{20}'
            | '\u{85}'
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

/// Characters matched by `\s` in a Dart (ECMAScript) regular expression.
/// Unlike `String.trim`, this excludes U+0085.
pub fn is_js_regexp_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{09}'..='\u{0D}'
            | '\u{20}'
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

pub fn trim(value: &str) -> &str {
    value.trim_matches(is_dart_trim_whitespace)
}

pub fn trim_left(value: &str) -> &str {
    value.trim_start_matches(is_dart_trim_whitespace)
}

pub fn trim_right(value: &str) -> &str {
    value.trim_end_matches(is_dart_trim_whitespace)
}

/// `value.trim().replaceAll(RegExp(r'\s+'), ' ')`.
pub fn collapse_whitespace(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut in_space = false;
    for c in trim(value).chars() {
        if is_js_regexp_whitespace(c) {
            if !in_space {
                result.push(' ');
                in_space = true;
            }
        } else {
            result.push(c);
            in_space = false;
        }
    }
    result
}

/// Dart `String.length`.
pub fn utf16_len(value: &str) -> usize {
    value.chars().map(char::len_utf16).sum()
}

/// Dart `value.substring(0, max)` when the result is stored through the
/// sqlite3 package: a surrogate pair split by the cut becomes U+FFFD, because
/// Dart's UTF-8 encoder replaces the lone high surrogate.
pub fn truncate_utf16(value: &str, max: usize) -> (String, bool) {
    if value.len() <= max || utf16_len(value) <= max {
        return (value.to_owned(), false);
    }
    let mut units = 0;
    let mut end = 0;
    let mut split_pair = false;
    for (index, c) in value.char_indices() {
        let width = c.len_utf16();
        if units + width > max {
            split_pair = units < max;
            end = index;
            break;
        }
        units += width;
        end = index + c.len_utf8();
    }
    let mut result = value[..end].to_owned();
    if split_pair {
        result.push('\u{FFFD}');
    }
    (result, true)
}

/// Dart `String.compareTo`: lexicographic by UTF-16 code unit.
pub fn compare_utf16(left: &str, right: &str) -> Ordering {
    left.encode_utf16().cmp(right.encode_utf16())
}

/// Dart `String.toLowerCase` uses simple one-to-one case mappings.
pub fn to_lower(value: &str) -> String {
    if value.is_ascii() {
        return value.to_ascii_lowercase();
    }
    value
        .chars()
        .map(|c| {
            let mut lower = c.to_lowercase();
            match (lower.next(), lower.next()) {
                (Some(single), None) => single,
                // U+0130 is the only character whose full mapping has more
                // than one character; its simple mapping is ASCII `i`.
                (Some(first), Some(_)) => first,
                (None, _) => c,
            }
        })
        .collect()
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut hex = String::with_capacity(64);
    for byte in digest.iter() {
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

// ---------------------------------------------------------------------------
// DateTime

const MICROS_PER_DAY: i64 = 86_400_000_000;
const MAX_MICROS: i64 = 8_640_000_000_000_000_000;

/// A Dart `DateTime` instant in UTC microseconds since the epoch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DartDateTime(pub i64);

impl DartDateTime {
    pub fn from_micros(micros: i64) -> Self {
        Self(micros)
    }

    /// `DateTime.now().toUtc()`.
    pub fn now() -> Self {
        Self(chrono::Utc::now().timestamp_micros())
    }

    pub fn micros(self) -> i64 {
        self.0
    }

    /// `DateTime.tryParse(value)?.toUtc()`.
    pub fn try_parse(value: &str) -> Option<Self> {
        parse_dart_date_time(value).map(Self)
    }

    /// `toUtc().toIso8601String()`.
    pub fn to_iso8601(self) -> String {
        let days = self.0.div_euclid(MICROS_PER_DAY);
        let mut rest = self.0.rem_euclid(MICROS_PER_DAY);
        let (year, month, day) = civil_from_days(days);
        let hour = rest / 3_600_000_000;
        rest %= 3_600_000_000;
        let minute = rest / 60_000_000;
        rest %= 60_000_000;
        let second = rest / 1_000_000;
        rest %= 1_000_000;
        let millisecond = rest / 1000;
        let microsecond = rest % 1000;
        let year_text = if (-9999..=9999).contains(&year) {
            four_digits(year)
        } else {
            six_digits(year)
        };
        let micro_text = if microsecond == 0 {
            String::new()
        } else {
            format!("{microsecond:03}")
        };
        format!(
            "{year_text}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millisecond:03}{micro_text}Z"
        )
    }

    pub fn is_after(self, other: Self) -> bool {
        self.0 > other.0
    }
}

fn four_digits(n: i64) -> String {
    let abs = n.unsigned_abs();
    let sign = if n < 0 { "-" } else { "" };
    if abs >= 1000 {
        return n.to_string();
    }
    if abs >= 100 {
        return format!("{sign}0{abs}");
    }
    if abs >= 10 {
        return format!("{sign}00{abs}");
    }
    format!("{sign}000{abs}")
}

fn six_digits(n: i64) -> String {
    let abs = n.unsigned_abs();
    let sign = if n < 0 { "-" } else { "+" };
    if abs >= 100_000 {
        return format!("{sign}{abs}");
    }
    format!("{sign}0{abs}")
}

/// Days since 1970-01-01 for a proleptic Gregorian date (month 1..=12).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = month;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn digits(&mut self, count: usize) -> Option<i64> {
        let end = self.pos + count;
        if end > self.bytes.len() || !self.bytes[self.pos..end].iter().all(u8::is_ascii_digit) {
            return None;
        }
        let mut value = 0i64;
        for byte in &self.bytes[self.pos..end] {
            value = value * 10 + i64::from(byte - b'0');
        }
        self.pos = end;
        Some(value)
    }

    fn at_end(&self) -> bool {
        self.pos == self.bytes.len()
    }
}

/// Port of `DateTime.parse` from the Dart SDK:
/// `^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$`
///
/// The regular expression backtracks over the 4-6 year digits; trying each
/// length from longest to shortest reproduces that.
fn parse_dart_date_time(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let (sign, start) = match bytes.first() {
        Some(b'+') => (1, 1),
        Some(b'-') => (-1, 1),
        _ => (1, 0),
    };
    for year_len in (4..=6).rev() {
        let mut cursor = Cursor { bytes, pos: start };
        let Some(year) = cursor.digits(year_len) else {
            continue;
        };
        if let Some(value) = parse_after_year(&mut cursor, sign * year) {
            return Some(value);
        }
    }
    None
}

fn parse_after_year(cursor: &mut Cursor<'_>, year: i64) -> Option<i64> {
    cursor.eat(b'-');
    let month = cursor.digits(2)?;
    cursor.eat(b'-');
    let day = cursor.digits(2)?;
    let mut minute = 0;
    let mut second = 0;
    let mut fraction_micros = 0;
    let mut is_utc = false;
    if cursor.at_end() {
        return broken_down_to_value(year, month, day, 0, 0, 0, 0, false);
    }
    // Everything after the date belongs to the optional time group.
    if !(cursor.eat(b' ') || cursor.eat(b'T')) {
        return None;
    }
    let hour = cursor.digits(2)?;
    let save = cursor.pos;
    // (?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?
    cursor.eat(b':');
    if let Some(m) = cursor.digits(2) {
        minute = m;
        let save_min = cursor.pos;
        cursor.eat(b':');
        if let Some(s) = cursor.digits(2) {
            second = s;
            let save_sec = cursor.pos;
            if cursor.eat(b'.') || cursor.eat(b',') {
                let digits_start = cursor.pos;
                while cursor.peek().is_some_and(|b| b.is_ascii_digit()) {
                    cursor.pos += 1;
                }
                if cursor.pos == digits_start {
                    cursor.pos = save_sec;
                } else {
                    let fraction = &cursor.bytes[digits_start..cursor.pos];
                    let mut value = 0i64;
                    for i in 0..6 {
                        value *= 10;
                        if let Some(byte) = fraction.get(i) {
                            value += i64::from(byte - b'0');
                        }
                    }
                    fraction_micros = value;
                }
            }
        } else {
            cursor.pos = save_min;
        }
    } else {
        cursor.pos = save;
    }
    // ( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?
    if !cursor.at_end() {
        let tz_start = cursor.pos;
        cursor.eat(b' ');
        match cursor.peek() {
            Some(b'z' | b'Z') => {
                cursor.pos += 1;
                is_utc = true;
            }
            Some(sign_byte @ (b'-' | b'+')) => {
                cursor.pos += 1;
                let hours = cursor.digits(2)?;
                let before_minutes = cursor.pos;
                cursor.eat(b':');
                let minutes = match cursor.digits(2) {
                    Some(value) => value,
                    None => {
                        cursor.pos = before_minutes;
                        0
                    }
                };
                let sign = if sign_byte == b'-' { -1 } else { 1 };
                minute -= sign * (minutes + 60 * hours);
                is_utc = true;
            }
            _ => {
                cursor.pos = tz_start;
            }
        }
    }
    if !cursor.at_end() {
        return None;
    }
    broken_down_to_value(
        year,
        month,
        day,
        hour,
        minute,
        second,
        fraction_micros,
        is_utc,
    )
}

#[allow(clippy::too_many_arguments)]
fn broken_down_to_value(
    mut year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    fraction_micros: i64,
    is_utc: bool,
) -> Option<i64> {
    let mut month0 = month - 1;
    if month0 >= 12 {
        year += month0 / 12;
        month0 %= 12;
    } else if month0 < 0 {
        let real = month0.rem_euclid(12);
        year += (month0 - real) / 12;
        month0 = real;
    }
    let days = days_from_civil(year, month0 + 1, 1) + day - 1;
    let mut micros = days
        .checked_mul(MICROS_PER_DAY)?
        .checked_add(hour * 3_600_000_000)?
        .checked_add(minute * 60_000_000)?
        .checked_add(second * 1_000_000)?
        .checked_add(fraction_micros)?;
    if !is_utc {
        micros = local_to_utc_micros(micros)?;
    }
    if micros.abs() > MAX_MICROS {
        return None;
    }
    Some(micros)
}

fn local_to_utc_micros(local_micros: i64) -> Option<i64> {
    use chrono::{DateTime, Local, LocalResult, NaiveDateTime, TimeZone};
    let naive: NaiveDateTime = DateTime::from_timestamp_micros(local_micros)?.naive_utc();
    let resolved = match Local.from_local_datetime(&naive) {
        LocalResult::Single(value) => value,
        LocalResult::Ambiguous(first, _) => first,
        LocalResult::None => {
            // In a DST gap Dart applies the offset in effect before the gap.
            let earlier = naive - chrono::Duration::hours(1);
            let offset = Local
                .from_local_datetime(&earlier)
                .earliest()?
                .offset()
                .local_minus_utc();
            return Some(local_micros - i64::from(offset) * 1_000_000);
        }
    };
    Some(resolved.timestamp_micros())
}

// ---------------------------------------------------------------------------
// JSON

/// Dart `jsonEncode` for a decoded JSON value.
pub fn json_encode(value: &Value) -> String {
    let mut out = String::new();
    write_json(&mut out, value);
    out
}

fn write_json(out: &mut String, value: &Value) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => out.push_str(&number_to_string(number)),
        Value::String(text) => write_json_string(out, text),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_json(out, item);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            for (index, (key, item)) in map.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_json_string(out, key);
                out.push(':');
                write_json(out, item);
            }
            out.push('}');
        }
    }
}

pub fn write_json_string(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{09}' => out.push_str("\\t"),
            '\u{0A}' => out.push_str("\\n"),
            '\u{0C}' => out.push_str("\\f"),
            '\u{0D}' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A JSON integer that Dart decodes as `int`; larger integers become doubles.
pub fn json_int(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_i64(),
        _ => None,
    }
}

fn number_to_string(number: &serde_json::Number) -> String {
    if let Some(value) = number.as_i64() {
        return value.to_string();
    }
    // Integers above i64::MAX and all fractional/exponent literals are doubles
    // in Dart.
    let value = number.as_f64().unwrap_or(f64::NAN);
    double_to_string(value)
}

/// Dart `double.toString()`: shortest round-trip digits, decimal notation for
/// 1e-6 <= |x| < 1e21, exponent notation with an explicit sign otherwise, and
/// `.0` appended to integral decimal output.
pub fn double_to_string(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_owned();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_owned();
    }
    if value == 0.0 {
        return if value.is_sign_negative() {
            "-0.0"
        } else {
            "0.0"
        }
        .to_owned();
    }
    let formatted = format!("{:e}", value.abs());
    let (mantissa, exponent) = formatted.split_once('e').expect("LowerExp has an exponent");
    let exponent: i32 = exponent.parse().expect("LowerExp exponent is an integer");
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let k = digits.len() as i32;
    let n = exponent + 1;
    let mut text = String::new();
    if value < 0.0 {
        text.push('-');
    }
    if k <= n && n <= 21 {
        text.push_str(&digits);
        for _ in 0..(n - k) {
            text.push('0');
        }
        text.push_str(".0");
    } else if 0 < n && n <= 21 {
        text.push_str(&digits[..n as usize]);
        text.push('.');
        text.push_str(&digits[n as usize..]);
    } else if -6 < n && n <= 0 {
        text.push_str("0.");
        for _ in 0..(-n) {
            text.push('0');
        }
        text.push_str(&digits);
    } else {
        text.push_str(&digits[..1]);
        if k > 1 {
            text.push('.');
            text.push_str(&digits[1..]);
        }
        text.push('e');
        text.push(if n > 0 { '+' } else { '-' });
        text.push_str(&(n - 1).abs().to_string());
    }
    text
}

/// Dart `Object.toString()` for a decoded JSON value, used where the Dart
/// parser interpolates a non-map message into `{'content': value.toString()}`.
pub fn to_dart_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number_to_string(number),
        Value::String(text) => text.clone(),
        Value::Array(items) => {
            let parts: Vec<String> = items.iter().map(to_dart_string).collect();
            format!("[{}]", parts.join(", "))
        }
        Value::Object(map) => {
            let parts: Vec<String> = map
                .iter()
                .map(|(key, item)| format!("{key}: {}", to_dart_string(item)))
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
    }
}

/// Decode one JSON document without a nesting limit, like Dart's iterative
/// parser, while keeping deep input off the fixed thread stack.
pub fn json_decode(text: &str) -> Result<Value, serde_json::Error> {
    let mut deserializer = serde_json::Deserializer::from_str(text);
    deserializer.disable_recursion_limit();
    let deserializer = serde_stacker::Deserializer::new(&mut deserializer);
    let value = serde::Deserialize::deserialize(deserializer)?;
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncation_counts_utf16_units_and_replaces_a_split_pair() {
        assert_eq!(truncate_utf16("abc", 3), ("abc".to_owned(), false));
        assert_eq!(truncate_utf16("abcd", 3), ("abc".to_owned(), true));
        assert_eq!(truncate_utf16("a😀b", 2), ("a\u{FFFD}".to_owned(), true));
        assert_eq!(truncate_utf16("a😀b", 3), ("a😀".to_owned(), true));
    }

    #[test]
    fn trim_matches_dart_whitespace() {
        assert_eq!(trim("\u{FEFF} x \u{85}"), "x");
        assert_eq!(collapse_whitespace(" a \u{85} b\t\nc "), "a \u{85} b c");
    }

    #[test]
    fn parses_and_formats_like_dart() {
        let parse = |text: &str| DartDateTime::try_parse(text).map(DartDateTime::to_iso8601);
        assert_eq!(
            parse("2026-01-02T03:04:05.123Z").as_deref(),
            Some("2026-01-02T03:04:05.123Z")
        );
        assert_eq!(
            parse("2026-01-02T03:04:05Z").as_deref(),
            Some("2026-01-02T03:04:05.000Z")
        );
        assert_eq!(
            parse("2026-01-02T03:04:05.1234567Z").as_deref(),
            Some("2026-01-02T03:04:05.123456Z")
        );
        assert_eq!(
            parse("2026-01-02T03:04:05+02:00").as_deref(),
            Some("2026-01-02T01:04:05.000Z")
        );
        assert_eq!(
            parse("20260102T030405Z").as_deref(),
            Some("2026-01-02T03:04:05.000Z")
        );
        assert_eq!(
            parse("2026-13-01T00:00:00Z").as_deref(),
            Some("2027-01-01T00:00:00.000Z")
        );
        assert_eq!(parse("not a date"), None);
        assert_eq!(parse("2026-01-02T03:04:05Zx"), None);
        assert_eq!(parse(""), None);
    }

    #[test]
    fn doubles_print_like_dart() {
        assert_eq!(double_to_string(5.0), "5.0");
        assert_eq!(double_to_string(1.5), "1.5");
        assert_eq!(double_to_string(1e21), "1e+21");
        assert_eq!(
            double_to_string(1.2345678901234568e20),
            "123456789012345680000.0"
        );
        assert_eq!(double_to_string(1e-7), "1e-7");
        assert_eq!(double_to_string(0.000001), "0.000001");
        assert_eq!(double_to_string(-2.5e-8), "-2.5e-8");
    }

    #[test]
    fn json_encode_matches_dart() {
        let value = json_decode(r#"{"b":1,"a":[1.0,"x\u0001\n/é"],"c":null,"d":1e2}"#).unwrap();
        assert_eq!(
            json_encode(&value),
            "{\"b\":1,\"a\":[1.0,\"x\\u0001\\n/é\"],\"c\":null,\"d\":100.0}"
        );
        assert_eq!(
            to_dart_string(&json_decode(r#"[1,{"a":"b"},2.0]"#).unwrap()),
            "[1, {a: b}, 2.0]"
        );
    }

    #[test]
    fn utf16_ordering_differs_from_utf8_for_astral_characters() {
        assert_eq!(compare_utf16("\u{FF61}", "\u{1F600}"), Ordering::Greater);
    }
}
