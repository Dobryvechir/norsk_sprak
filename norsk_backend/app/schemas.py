"""
Request bodies (what clients send in JSON).

FastAPI validates incoming JSON against these models automatically and replies
with 422 and a description of the problem if it doesn't match.
"""

from typing import Literal

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    email: str
    password: str


class CreateUserRequest(BaseModel):
    email: str
    password: str = Field(min_length=10)


class SignupFields(BaseModel):
    """The sign-up form's fields (body of POST /api/checksum)."""

    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=10, max_length=200)
    info: str = Field(default="", max_length=2000)  # who they are / why they want access


class SignupRequest(SignupFields):
    """A request for an account; a system admin approves or rejects it.
    `checksum` is what POST /api/checksum returned for the same fields."""

    checksum: str = Field(max_length=128)
    captchaToken: str = Field(max_length=1000)    # from POST /api/captcha
    captchaSolution: int = Field(ge=0, le=2**53)  # the proof-of-work answer
    website: str = Field(default="", max_length=200)  # honeypot: must stay empty


class ApproveCandidateRequest(BaseModel):
    """Optionally put the approved user straight into a group."""

    groupId: str | None = None
    role: str = "viewer"  # "viewer", "uploader" or "admin"


class GroupChatSettings(BaseModel):
    """A group's chat settings (see chat.GROUP_CHAT_DEFAULTS). In a PATCH, fields
    left out (null) keep their current value."""

    anonymous: bool | None = None
    family: bool | None = None
    subgroupLimitPerYear: int | None = Field(default=None, ge=0, le=10000)
    chatPerDayKb: int | None = Field(default=None, ge=1, le=100000)
    expirationDays: int | None = Field(default=None, ge=1, le=3650)


class CreateGroupRequest(GroupChatSettings):
    """A new group; chat settings left out get their defaults."""

    name: str = Field(min_length=1, max_length=100)


# --- Chat ---

class ChatProfileRequest(BaseModel):
    """The name shown in Chat and, optionally, a new small photo (base64 PNG or
    JPEG, at most 64 kB). Without `photo` the current photo is kept."""

    displayName: str = Field(min_length=1, max_length=60)
    photo: str | None = Field(default=None, max_length=90000)


class ChatAttachment(BaseModel):
    """A link to a file the sender shared from their own Google Drive."""

    kind: Literal["picture", "audio", "video", "file"]
    name: str = Field(min_length=1, max_length=200)
    url: str = Field(min_length=1, max_length=500)  # https://drive.google.com/... or docs.google.com
    driveId: str = Field(default="", max_length=200, pattern=r"^[A-Za-z0-9_-]*$")
    mimeType: str = Field(default="", max_length=100)
    size: int | None = Field(default=None, ge=0)


class ChatMessageRequest(BaseModel):
    text: str = Field(default="", max_length=4000)
    attachments: list[ChatAttachment] = Field(default_factory=list, max_length=10)


class CreateSubgroupRequest(BaseModel):
    groupId: str
    name: str = Field(min_length=1, max_length=100)
    family: bool = False


class InviteRequest(BaseModel):
    userIds: list[str] = Field(min_length=1, max_length=50)


class DirectChatRequest(BaseModel):
    groupId: str
    userId: str


class LocationRequest(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    accuracy: float | None = Field(default=None, ge=0)


class MemberRequest(BaseModel):
    """Add a user to a group, or change their role/quota/enabled state."""

    role: str = "viewer"  # "viewer", "uploader" or "admin" (checked in the endpoint)
    enabled: bool = True
    # Optional limits, each a non-negative int or null (= unlimited):
    #   max_recordings_per_month, max_audio_minutes_per_month,
    #   max_recording_duration_minutes
    quota: dict = {}


class AIConfigRequest(BaseModel):
    """Per-group transcription settings."""

    provider: str = "openai"
    model: str = "whisper-1"
    # Total audio minutes the whole group may upload per month; null = unlimited.
    monthly_audio_minutes_limit: int | None = None


class SentenceEditRequest(BaseModel):
    """Correct one sentence in one language: its text, its timing in that
    language's audio, or both. Timing needs both start_ms and end_ms."""

    text: str | None = Field(default=None, min_length=1)
    start_ms: int | None = Field(default=None, ge=0)
    end_ms: int | None = Field(default=None, gt=0)


# --- Plan, shop and email verification (routes/plans.py) ---

class CandidateRef(BaseModel):
    """Which candidate a /plan/ or /shop/ call is for; `token` is the plan token
    POST /api/signup returned (it proves the caller is the one who signed up)."""

    candidateId: str = Field(max_length=64)
    token: str = Field(max_length=128)


class ChoosePlanRequest(CandidateRef):
    plan: Literal["basic", "pro"]


class StartPaymentRequest(CandidateRef):
    currency: Literal["EUR", "USD", "NOK"]


class VerifyEmailRequest(BaseModel):
    token: str = Field(min_length=10, max_length=200)
