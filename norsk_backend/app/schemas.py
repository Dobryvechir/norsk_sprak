"""
Request bodies (what clients send in JSON).

FastAPI validates incoming JSON against these models automatically and replies
with 422 and a description of the problem if it doesn't match.
"""

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    email: str
    password: str


class CreateUserRequest(BaseModel):
    email: str
    password: str = Field(min_length=10)


class CreateGroupRequest(BaseModel):
    name: str = Field(min_length=1, max_length=100)


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
    """Correct one transcribed sentence's text and/or timing."""

    text: str = Field(min_length=1)
    start_ms: int = Field(ge=0)
    end_ms: int = Field(gt=0)
