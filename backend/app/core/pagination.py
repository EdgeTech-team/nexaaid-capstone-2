"""NF-003 (NEW FEATURE): one pagination standard for every list endpoint.

How a list endpoint uses it:

    from fastapi import Depends, Response
    from core.pagination import PageParams, paginate_query, set_total_header

    @router.get("/things")
    def list_things(response: Response, page: PageParams = Depends(), ...):
        rows, total = paginate_query(query, page, Thing.created_at.desc(), Thing.thing_id.desc())
        set_total_header(response, page, total)
        return rows

Rules (T1, option A approved by the team):
- limit and offset are optional query parameters. Without limit the endpoint
  answers exactly as before (no slicing, no header), so APKs that testers
  already installed keep working against the new backend.
- limit < 1 or offset < 0 -> 422. limit > 100 is clamped to 100.
- offset without limit is ignored (paging only starts when limit is sent).
- The response stays a JSON array. The number of matching rows is sent in
  the X-Total-Count header (exposed to the web build in main.py's CORS).
- Every page must use a stable order that ends on a unique column (the id),
  so rows with equal timestamps never repeat or go missing between pages.
"""
from typing import Optional, Sequence, Tuple

from fastapi import Query, Response

MAX_LIMIT = 100
TOTAL_HEADER = "X-Total-Count"


class PageParams:
    """FastAPI dependency: `page: PageParams = Depends()`."""

    def __init__(
        self,
        limit: Optional[int] = Query(
            None, ge=1,
            description=f"Page size (1 or more, values above {MAX_LIMIT} are "
                        f"treated as {MAX_LIMIT}). Leave out for the full list.",
        ),
        offset: int = Query(
            0, ge=0, description="Rows to skip. Only used together with limit.",
        ),
    ):
        self.limit = min(limit, MAX_LIMIT) if limit is not None else None
        self.offset = offset

    @property
    def requested(self) -> bool:
        """True when the caller asked for a page (sent limit)."""
        return self.limit is not None


def paginate_list(items: Sequence, page: PageParams) -> Tuple[list, int]:
    """Slice a list that is already filtered and sorted.

    Returns (page_items, total). Without limit the list comes back whole.
    """
    total = len(items)
    if not page.requested:
        return list(items), total
    return list(items[page.offset:page.offset + page.limit]), total


def paginate_query(query, page: PageParams, *order_by) -> Tuple[list, int]:
    """Count, order and page a SQLAlchemy query with the SAME filters.

    order_by must end on a unique column (e.g. Model.id.desc()) so pages are
    stable. Returns (rows, total). Without limit all rows come back.
    """
    if not order_by:
        raise ValueError("paginate_query needs an order ending on a unique column")
    total = query.order_by(None).count()
    ordered = query.order_by(*order_by)
    if not page.requested:
        return ordered.all(), total
    return ordered.offset(page.offset).limit(page.limit).all(), total


def set_total_header(response: Response, page: PageParams, total: int) -> None:
    """Send X-Total-Count, but only for a paged request: an old app that
    sends no limit gets the response byte-for-byte as before."""
    if page.requested:
        response.headers[TOTAL_HEADER] = str(total)


def parse_ids(text: str, most: int = MAX_LIMIT) -> list:
    """A comma list of ids ("3,7,12") from a query parameter, for "the rows
    of one page only" lookups. 422 for anything else or more than `most`."""
    from fastapi import HTTPException
    parts = [p.strip() for p in text.split(",") if p.strip()]
    if len(parts) > most or not all(p.isdigit() for p in parts):
        raise HTTPException(status_code=422, detail=f"Give up to {most} ids, comma separated")
    return [int(p) for p in parts]
