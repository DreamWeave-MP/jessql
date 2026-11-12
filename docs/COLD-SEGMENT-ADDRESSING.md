# RFC: addressing cold data in segment files (#20)

Status: **draft for review**, with a prototype (`@jessql/coldaddress`, `tests/coldaddress.jsl`).
No existing format changes and nothing reads or writes segment files outside the prototype.

## The problem

A cold file is addressed by one byte offset held in a Luau number. A number is exact to
2^53 - 1, so the arithmetic is safe today; what is not safe is the next step, where an offset
is written as a 32-bit field (4 GiB) or a file must be kept under a filesystem's or a tool's
size limit. The answer is more than one file, and then an address is two things.

## The address

| Field | Width | Range |
|---|---|---|
| segment id | unsigned 32-bit, low byte first | 0 to 2^32 - 1 |
| offset in the segment | unsigned 32-bit, low byte first | 0 to `segmentBytes` - 1 |

Eight bytes, segment first. Every segment of a set has the same capacity, `segmentBytes`, a
power of two from 4 KiB to 2 GiB, recorded once for the set. So an offset always fits 31 bits,
a decoded offset at or past `segmentBytes` is **damage** and refused, and a set of 1 GiB
segments addresses 2^62 bytes.

## Logical offsets, and where they stop

`logical = segment * segmentBytes + offset` is offered because callers think in one number.
It is produced only when exact: `split` refuses anything that is not a whole number from 0 to
2^53 - 1, and `join` compares before it multiplies and refuses a pair whose logical offset
would pass 2^53 - 1 (`no exact logical offset: carry the pair`). Past that point the pair is
the address and there is no number. Nothing is clamped, wrapped or rounded.

## Reads

A read of `length` bytes at an address is cut into one piece a segment. It is refused when it
names a segment the set does not list, when it runs past a segment's **recorded** length (not
its capacity), when the file is shorter than the set says, or when it would touch more than
4,096 segments. A set need not start at segment 0 and may have gaps: retired segments are
simply not listed, and a read into a gap fails.

## Rotation and checksums (prototype)

The prototype writer fills segments in order, seals one when it is full, and creates each
file exclusively: a segment file is written once. The set records each segment's id, length
and CRC-32; `verify` reads a segment whole against them. A read does **not** verify: it is
held to lengths only. **Open for review:** whether the checksum belongs to the segment (as
here), to pages inside it (as cold pages have today), or both; and CRC-32 against something
stronger. The prototype holds a whole segment in memory to seal or verify it, which is its
limit and not a proposal.

## File names

`<base>.s<id as eight lower-case hex digits>.cold`. Fixed width, so names sort as ids do;
lower case, so two segments never differ by case alone on a case-insensitive filesystem. A
base is letters, digits, `_` and `-`, starting with a letter or digit, 48 characters at most
(a name of 63, well inside every platform's limit), and not a Windows device name in any case
(`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`).

## What the tests hold

Split and join at 0, at each side of a segment edge, at 4 GiB, at 2^40 and at 2^53 - 1, and
the refusals one past each limit; the eight bytes, byte for byte; names; a 30,000-byte stream
over 4 KiB segment files read back whole and in pieces across edges; real files under segment
ids 5, 6, 2^23 - 1 and 2^23 of a 1 GiB set, read at logical offsets up to 2^53 - 1 and, past
it, by pair; and a changed byte, a shortened file, a missing file, and sets that are out of
order, repeated or too long.

## Not done

- Nothing in the storage engine uses this. Wiring it under cold pages, and the manifest
  fields for a set, are a format change and a separate decision.
- No file of 4 GiB was written: the large offsets come from large segment ids over small
  files, which exercises the arithmetic and the reader and not a filesystem.
- Not run on Windows; the name rules are from its documented restrictions.
- No measurement.
