from pydantic import BaseModel
from typing import List, list, Optional

class statusCount(BaseModel):
    status: str
    count: int

class PriorityCount(BaseModel):
    priority_level: Optional[str]
    count: int

class DashboardSummary(BaseModel):
    total_reports: int
    total_donation: int
    total_delivered: int
    total_logistics_requests: int
    active_organizations: int

class reportsBreakdown(BaseModel):
    by_status: List[statusCount]
    by_priority: List[PriorityCount]

class DonationBreakdown(BaseModel):
    by_status: List[statusCount]
    total_estimated_value: float

class FulfillmentOverview(BaseModel):
    average_fulfillment_percentage: float
    fully_verified_count: int
    pending_verification_count: int

class LogisticsOverview(BaseModel):
    deliveries_by_status: List[statusCount]
    request_by_status: List[statusCount]
