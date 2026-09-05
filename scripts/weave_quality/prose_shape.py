"""What a repair sweep turns prose into, which finding counts cannot show.

Every prose rule counts occurrences of a construction, and every gate built on
them counts findings. That pair answers how often we write something and never
answers what the repairs leave behind. A consumer measured a sweep of 32
clause-accretion findings and found sentence count 904 -> 942, terminators
857 -> 896, coordinated joins 308 -> 285, words 23,211 -> 23,195: joins became
full stops roughly one for one, the document did not shorten, and the prose
moved toward a monotone while every rule improved on its own metric. One guide
offering one corrective move, applied 32 times, produces 32 full stops
(wv-8b5432).

The continuation mix is the readout, not the sentence count. A split-only sweep
drives `coord_pct` down and moves nothing into `subord_pct` or `phrase_pct`,
because it converts joins into full stops rather than into another relationship.
A sweep that actually rewrote would show the second movement.

MEASURE BOTH SIDES THE SAME WAY. `--baseline` profiles the same paths at a git
ref through this identical code path, because a comparison is only as good as
the symmetry of its halves. The provenance of a rule elsewhere in this project
recorded our sentences at 26.9 words against 21.1 published, a gap that did not
survive measuring both corpora under one treatment (23.8 against 23.8).

NO VERDICT IS OFFERED. The consumer's harness carries thresholds -- a reference
coefficient of variation, a minimum variance drop -- calibrated against its own
corpus and its own register guide. Those are that repository's business. This
reports the numbers and names what a flattening looks like; whether a given
movement is acceptable is a judgement about a specific document.
"""

from __future__ import annotations

import re
import statistics as st
from pathlib import Path

_MASK = "\x00"

# How a sentence continues after a comma. Three different relationships, so the
# mix says which repair move a sweep reached for.
_COORD = re.compile(r",\s+(?:and|but|or|nor|yet|so)\s")
_SUBORD = re.compile(
    r",\s+(?:which|where|while|when|whose|since|because|although|though|if)\s"
)
_PHRASE = re.compile(
    r",\s+(?:with|without|at|for|by|from|against|under|over|through|despite"
    r"|after|before|leaving|giving|carrying|showing|using)\s"
)


def strip_markdown(text: str) -> str:
    """Prose only: no frontmatter, fences, tables, headings, code spans or links.

    Headings and table rows go because neither is a sentence, and leaving them
    in is what produced a 26.9-word average in an earlier measurement -- an
    unstripped table has no full stop and reads as one enormous sentence.
    """
    text = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"^\s*\|.*$", " ", text, flags=re.M)
    text = re.sub(r"^#+ .*$", " ", text, flags=re.M)
    text = re.sub(r"`[^`]*`", "CODE", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return re.sub(r"[*_~]", "", text)


def sentences(text: str, *, lo: int = 4, hi: int = 120) -> list[str]:
    """Split into sentences, guarding the three things that split falsely.

    A decimal point, a section number and a short list of abbreviations end no
    sentence. Each is masked, split around, and restored, so "0.558 to 0.726"
    stays one sentence and a following capital still opens the next. The
    `lo`/`hi` word bounds drop fragments and any run that escaped stripping.
    """
    flat = " ".join(text.split())
    flat = re.sub(r"(\d)\.(\d)", rf"\1{_MASK}\2", flat)
    flat = re.sub(
        r"§(\d+(?:\.\d+)*)", lambda m: "§" + m.group(1).replace(".", _MASK), flat
    )
    flat = re.sub(
        r"\b(e\.g|i\.e|cf|vs|al|Fig|Eq|approx|no)\.", rf"\1{_MASK}", flat, flags=re.I
    )
    out: list[str] = []
    for part in re.split(r'(?<=[.!?])\s+(?=[A-Z(§"“])', flat):
        part = part.replace(_MASK, ".").strip()
        if lo <= len(part.split()) <= hi:
            out.append(part)
    return out


def profile(sents: list[str]) -> dict[str, float | int]:
    """Shape of one sentence set. Empty input profiles as zero, not as an error."""
    if not sents:
        return {
            "sentences": 0, "words": 0, "mean_length": 0.0, "sd_length": 0.0,
            "cv_length": 0.0, "coord_pct": 0.0, "subord_pct": 0.0, "phrase_pct": 0.0,
        }
    lens = [len(s.split()) for s in sents]
    n = len(sents)
    mean = st.mean(lens)
    sd = st.pstdev(lens)
    return {
        "sentences": n,
        "words": sum(lens),
        "mean_length": round(mean, 2),
        "sd_length": round(sd, 2),
        # Normalised, so a document of shorter sentences is not read as flatter
        # merely for being shorter.
        "cv_length": round(sd / mean, 4) if mean else 0.0,
        "coord_pct": round(sum(bool(_COORD.search(s)) for s in sents) / n * 100, 2),
        "subord_pct": round(sum(bool(_SUBORD.search(s)) for s in sents) / n * 100, 2),
        "phrase_pct": round(sum(bool(_PHRASE.search(s)) for s in sents) / n * 100, 2),
    }


def profile_markdown(text: str) -> dict[str, float | int]:
    """The one treatment. Both sides of any comparison must come through here."""
    return profile(sentences(strip_markdown(text)))


def profile_texts(texts: list[str]) -> dict[str, float | int]:
    """Profile several documents as one body of prose."""
    sents: list[str] = []
    for text in texts:
        sents.extend(sentences(strip_markdown(text)))
    return profile(sents)


def markdown_files(target: Path) -> list[Path]:
    """The .md files under target, or target itself when it is one."""
    if target.is_file():
        return [target] if target.suffix.lower() == ".md" else []
    return sorted(p for p in target.rglob("*.md") if p.is_file())
