"""The "stage" of a logistics request, in SQL (NF-001 / NF-003).

api/v1/drrmo_router.request_rows gives every request a stage: its status,
except that an Accepted request whose delivery has left CSWS (In Transit,
Delivered or Confirmed) reads "In Transit" (UC-DR2) until DRRMO completes it.
The DRRMO and records screens filter and count by that stage, so the same
rule is written here once as SQL, for GET /drrmo/requests and
GET /logistics/requests.
"""
from sqlalchemy import and_, case, exists

from models.deliveries.delivery import Delivery
from models.deliveries.logistics_request_model import LogisticsRequest

LEFT_THE_OFFICE = ("In Transit", "Delivered", "Confirmed")


def _left_the_office():
    return exists().where(Delivery.delivery_id == LogisticsRequest.delivery_id,
                          Delivery.status.in_(LEFT_THE_OFFICE))


def stage_is(stage: str):
    """WHERE condition: the request's stage is `stage`."""
    left = _left_the_office()
    if stage == "In Transit":
        return and_(LogisticsRequest.status == "Accepted", left)
    if stage == "Accepted":
        return and_(LogisticsRequest.status == "Accepted", ~left)
    return LogisticsRequest.status == stage


def stage_column():
    """The stage as a SQL expression (for GROUP BY counts)."""
    return case(
        (and_(LogisticsRequest.status == "Accepted", _left_the_office()), "In Transit"),
        else_=LogisticsRequest.status,
    )
