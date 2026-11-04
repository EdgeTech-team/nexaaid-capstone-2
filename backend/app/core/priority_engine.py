from datetime import datetime, timezone

# Testing, Module 3: a report whose needs are fully delivered ("Complete")
# must stop competing for donations. Its score is capped just below the
# Medium threshold (35), so it always reads Low. The weights above are
# unchanged for every report that is not fully fulfilled.
FULFILLED_SCORE_CAP = 34.99

VALID_LEVELS = ("Low", "Medium", "High", "Critical")

# Option C (Oct 2026 team decision): priority = how severe x how much is
# still missing.
#   severity = affected families and disaster type, in the 40 : 30 ratio the
#              team chose (option A), i.e. 4/7 and 3/7 of the severity score.
#   missing  = 100 - the report's delivered fulfillment % (per item, averaged;
#              services/fulfillment.py). It scales the severity from 100%
#              (nothing delivered) down to MISSING_FLOOR (almost everything
#              delivered), so the level steps down as goods arrive instead of
#              sitting at High and jumping to Low at the end.
#   100% delivered is always Low (FULFILLED_SCORE_CAP).
# Example, 120 families + Flood (severity 87): 0% delivered 87 Critical,
# 30% 71 High, 50% 61 High, 70% 50 Medium, 90% 40 Medium, 100% Low.
SEVERITY_WEIGHTS = {"families": 4 / 7, "disaster_type": 3 / 7}
MISSING_FLOOR = 0.40

DISASTER_SEVERITY = {
    "Flood": 70,
    "Typhoon": 85,
    "Fire": 60,
    "Earthquake": 90,
    "Flash Flood": 75,
    "Storm Surge": 85,
    "Landslide": 80,
    "Tsunami": 95,
    "Drought": 55,
    "Disease Outbreak": 65,
    # Not one of the listed types: scored like an unknown type.
    "Other": 50,
}


# (at least this many families, score), highest first. 1-9 families = 10.
FAMILY_TIERS = ((100, 100), (50, 75), (20, 50), (10, 25), (1, 10))

# (score at least, level), most urgent first. Below 35 = Low.
LEVEL_THRESHOLDS = ((80, "Critical"), (60, "High"), (35, "Medium"))


# A disaster type with no entry above (or none at all).
UNKNOWN_DISASTER_SEVERITY = 50


def score_affected_families(affected_families):

    if not affected_families or affected_families <= 0:
        return 0
    for at_least, score in FAMILY_TIERS:
        if affected_families >= at_least:
            return score
    return 0

def score_fulfillment(verification_status):

    if verification_status == "Not Started":
        return 100
    elif verification_status == "Partial":
        return 50
    elif verification_status == "Complete":
        return 0
    else :
        return 100

def missing_share(fulfillment) -> float:
    """How much of the report's needs is still missing, 0.0 to 1.0, from the
    delivered percentage (testing #2: "Partial" used to count as 50 whether
    5% or 95% had arrived). No fulfillment record yet = all missing (alt 2a)."""
    if fulfillment is None:
        return 1.0
    if fulfillment.verification_status == "Complete":
        return 0.0
    pct = fulfillment.fulfillment_percentage
    if pct is None:
        return {"Partial": 0.5}.get(fulfillment.verification_status, 1.0)
    return max(0.0, min(1.0, 1 - float(pct) / 100))


def score_estimated_quantity(estimated_quantity):

    if not estimated_quantity or estimated_quantity <= 0:
        return 0

    if estimated_quantity >= 100:
        return 100
    elif estimated_quantity >= 50:
        return 75
    elif estimated_quantity >= 25:
        return 50
    elif estimated_quantity >= 10:
        return 25
    else:
        return 10


def score_disaster_type(report):

    if not report.disaster_type:
       return UNKNOWN_DISASTER_SEVERITY

    disaster_type_name = report.disaster_type.type_name
   
    return DISASTER_SEVERITY.get(disaster_type_name, UNKNOWN_DISASTER_SEVERITY)


def compute_priority(report):
    if not report.affected_families and not report.estimated_quantity and not report.assistance_needed:
        return{
            "score": None,
            "priority_level": "Needs Review",
            "recommendation": "Insufficient data to compute priority.",
        }
    severity = (
        score_affected_families(report.affected_families) * SEVERITY_WEIGHTS["families"]
        + score_disaster_type(report) * SEVERITY_WEIGHTS["disaster_type"]
    )
    # Estimated quantity is not a factor (option A, Oct 2026): with per-item
    # needs it is a sum of different units (kg + L + pcs).
    missing = missing_share(report.fulfillment)
    score = severity * (MISSING_FLOOR + (1 - MISSING_FLOOR) * missing)

    if not (0 <= score <= 100):
        return {
            "score": None,
            "priority_level": "Review Required",
            "recommendation": "Computed score was out of expected range.",
        }

    priority_level = next(
        (level for at_least, level in LEVEL_THRESHOLDS if score >= at_least), "Low")

    recommendation = (
        f"Severity {severity:.0f} x {missing * 100:.0f}% of needs still missing."
    )
    if not report.fulfillment:
        recommendation = "Priority computed without data (2a: not yet validated/fulfilled)."
    elif report.fulfillment.verification_status == "Complete":
        score = min(score, FULFILLED_SCORE_CAP)
        priority_level = "Low"
        recommendation = "Fully fulfilled: every needed item was delivered and confirmed."

    return {
        "score": round(score, 2),
        "priority_level": priority_level,
        "recommendation": recommendation,
    }

def apply_priority(report):
    """Compute the priority and store it on the report. Used when a report is
    validated and again whenever its fulfillment changes (a delivery receipt),
    so the level never goes stale."""
    result = compute_priority(report)
    level = result["priority_level"]
    report.ai_priority_score = result["score"]
    # "Needs Review" / "Review Required" violate chk_disaster_reports_priority,
    # so store NULL and keep the reason in ai_recommendation.
    report.priority_level = level if level in VALID_LEVELS else None
    report.ai_recommendation = result["recommendation"]
    report.ai_processed_at = datetime.now(timezone.utc)
    return result


PRIORITY_MEANING = {
    "Critical": "Needs help immediately. Donations to this report are the most urgent.",
    "High": "Needs help soon. Donations here are a high priority.",
    "Medium": "Needs help, but is less urgent than Critical and High reports.",
    "Low": "Lower urgency. Other reports should be covered first.",
}


def explain_priority(report):
    """Plain-language guidance for the public landing page.
    Built from the same factors compute_priority scores; no personal data."""
    meaning = PRIORITY_MEANING.get(
        report.priority_level, "The City is still reviewing this report's priority."
    )
    reasons = []
    if report.affected_families:
        reasons.append(f"{report.affected_families} families affected")
    if report.disaster_type:
        reasons.append(f"{report.disaster_type.type_name} severity")
    f = report.fulfillment
    if f:
        reasons.append(f"{float(f.fulfillment_percentage):.0f}% of needs delivered")
    if reasons:
        return f"{meaning} Based on: {', '.join(reasons)}."
    return meaning