"""Readable report wording for notifications.

Notifications used to say "Report #21 is now accepting donations". Donors
and staff could not tell from that who needs help or with what. These
helpers turn a report into plain sentences:

    "Flood in Barangay Looc"                                 (label)
    "35 families in Barangay Looc were affected by a flood.
     They need rice, drinking water and 2 more items."       (story)

The report number stays in staff messages (they look reports up by it), but
never leads.
"""
from typing import Optional

from core.m2_disaster_reporting.report_model import DisasterReport

_VOWEL_SOUND = ("a", "e", "i", "o", "u")


def disaster_name(report: DisasterReport) -> str:
    return (report.disaster_type_name or "disaster").strip()


def place(report: DisasterReport) -> str:
    """'Sitio Ibabao, Barangay Looc', or 'Barangay Looc'."""
    brgy = (report.barangay_name or "").strip()
    brgy = brgy if not brgy or brgy.lower().startswith("barangay") else f"Barangay {brgy}"
    sitio = report.sitio.sitio_name.strip() if getattr(report, "sitio", None) else ""
    if sitio and not sitio.lower().startswith("sitio"):
        sitio = f"Sitio {sitio}"
    return ", ".join(p for p in (sitio, brgy) if p) or "the barangay"


def label(report: DisasterReport) -> str:
    """'Flood in Barangay Looc'."""
    brgy = (report.barangay_name or "").strip()
    brgy = brgy if not brgy or brgy.lower().startswith("barangay") else f"Barangay {brgy}"
    return f"{disaster_name(report).capitalize()} in {brgy or 'a barangay'}"


def needs_text(report: DisasterReport, limit: int = 3) -> Optional[str]:
    """'rice, drinking water and 2 more items', from the report's needs
    (or the typed 'assistance needed' of older reports)."""
    names = [n.item.item_name for n in (report.needs or []) if n.item is not None]
    if not names:
        typed = (report.assistance_needed or "").strip().rstrip(".")
        return typed or None
    shown = [n.lower() for n in names[:limit]]
    rest = len(names) - len(shown)
    if rest > 0:
        return f"{', '.join(shown)} and {rest} more item{'s' if rest != 1 else ''}"
    return shown[0] if len(shown) == 1 else f"{', '.join(shown[:-1])} and {shown[-1]}"


def _a(word: str) -> str:
    return ("an " if word[:1].lower() in _VOWEL_SOUND else "a ") + word


def story(report: DisasterReport) -> str:
    """'35 families in Barangay Looc were affected by a flood. They need
    rice and drinking water.'"""
    families = report.affected_families
    who = (f"{families} famil{'y' if families == 1 else 'ies'}" if families
           else "Families")
    verb = "was" if families == 1 else "were"
    text = f"{who} in {place(report)} {verb} affected by {_a(disaster_name(report).lower())}."
    needs = needs_text(report)
    if needs:
        text += f" They need {needs}."
    if report.priority_level in ("High", "Critical"):
        text += f" {report.priority_level} priority."
    return text
