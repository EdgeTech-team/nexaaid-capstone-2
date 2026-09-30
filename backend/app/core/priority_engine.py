
DISASTER_SEVERITY = {
    "Flood": 70,
    "Typhoon": 85,
    "Fire": 60,
    "Earthquake": 90,
    # Added with the demo seed's disaster types
    "Flash Flood": 75,
    "Storm Surge": 85,
    "Landslide": 80,
    "Tsunami": 95,
    "Volcanic Eruption": 90,
    "Drought": 55,
    "Disease Outbreak": 65,
}

def score_affected_families(affected_families):

    if not affected_families or affected_families <= 0:
        return 0
    if affected_families >=100:
        return 100
    elif affected_families >= 50:
        return 75
    elif affected_families >= 20:
        return 50
    elif affected_families >= 10:
        return 25
    else :
        return 10

def score_fulfillment(verification_status):

    if verification_status == "Not Started":
        return 100
    elif verification_status == "Partial":
        return 50
    elif verification_status == "Complete":
        return 0
    else :
        return 100

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
       return 50

    disaster_type_name = report.disaster_type.type_name
   
    return DISASTER_SEVERITY.get(disaster_type_name, 50)


def compute_priority(report):
    if not report.affected_families and not report.estimated_quantity and not report.assistance_needed:
        return{
            "score": None,
            "priority_level": "Needs Review",
            "recommendation": "Insufficient data to compute priority.",
        }
    families = score_affected_families(report.affected_families)
    quantity = score_estimated_quantity(report.estimated_quantity)
    severity = score_disaster_type(report)
    fulfillment = score_fulfillment(
        report.fulfillment.verification_status if report.fulfillment else None
    )

    score =(
        families *0.30
        + quantity *0.20
        + severity *0.25
        +fulfillment *0.25
    )

    if not (0 <= score <= 100):
        return {
            "score": None,
            "priority_level": "Review Required",
            "recommendation": "Computed score was out of expected range.",
        }

    if score >= 80:
        priority_level = "Critical"
    elif score >= 60:
        priority_level = "High"
    elif score >= 35:
        priority_level = "Medium"
    else :
        priority_level ="Low"

    recommendation = "Priority computed from report and fulfillment data."
    if not report.fulfillment:
        recommendation = "Priority computed without data (2a: not yet validated/fulfilled)."

    return {
        "score": round(score, 2),
        "priority_level": priority_level,
        "recommendation": recommendation,
    }
