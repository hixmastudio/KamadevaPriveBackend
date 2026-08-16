package domain

import (
	"context"
	"encoding/json"
	"time"
)

const (
	ChannelWhatsApp = "whatsapp"

	ConversationAIActive        = "AI_ACTIVE"
	ConversationWaitingForHuman = "WAITING_FOR_HUMAN"
	ConversationHumanActive     = "HUMAN_ACTIVE"
	ConversationClosed          = "CLOSED"

	DirectionInbound  = "INBOUND"
	DirectionOutbound = "OUTBOUND"

	SenderCustomer = "CUSTOMER"
	SenderAI       = "AI"
	SenderHuman    = "HUMAN"
	SenderSystem   = "SYSTEM"

	EventBookingCreated          = "booking.created"
	EventWhatsAppInboundReceived = "whatsapp.inbound.received"

	ActionStatusPending = "pending"
	ActionStatusSuccess = "success"
	ActionStatusFailed  = "failed"
)

type Conversation struct {
	ID              string          `json:"id"`
	CustomerID      string          `json:"customer_id"`
	BookingID       string          `json:"booking_id,omitempty"`
	Channel         string          `json:"channel"`
	Status          string          `json:"status"`
	AssignedAgentID string          `json:"assigned_agent_id,omitempty"`
	PendingAction   json.RawMessage `json:"pending_action,omitempty"`
	CreatedAt       time.Time       `json:"created_at"`
	UpdatedAt       time.Time       `json:"updated_at"`
}

type ConversationMessage struct {
	ID                string    `json:"id"`
	ConversationID    string    `json:"conversation_id"`
	ExternalMessageID string    `json:"external_message_id,omitempty"`
	Direction         string    `json:"direction"`
	SenderType        string    `json:"sender_type"`
	Body              string    `json:"body"`
	CreatedAt         time.Time `json:"created_at"`
}

type BookingSummary struct {
	ID          string    `json:"id"`
	CustomerID  string    `json:"customer_id"`
	ServiceID   string    `json:"service_id,omitempty"`
	ServiceName string    `json:"service_name,omitempty"`
	Status      string    `json:"status"`
	StartsAt    time.Time `json:"starts_at"`
	EndsAt      time.Time `json:"ends_at,omitempty"`
}

type CustomerSummary struct {
	ID    string `json:"id"`
	Name  string `json:"name,omitempty"`
	Phone string `json:"phone"`
}

type AvailableSlot struct {
	ID       string    `json:"id"`
	StartsAt time.Time `json:"starts_at"`
	EndsAt   time.Time `json:"ends_at"`
}

type BusinessInformation struct {
	CompanyName        string            `json:"company_name"`
	Location           string            `json:"location,omitempty"`
	OpeningHours       string            `json:"opening_hours,omitempty"`
	CancellationPolicy string            `json:"cancellation_policy,omitempty"`
	Services           []string          `json:"services,omitempty"`
	Extra              map[string]string `json:"extra,omitempty"`
}

type OutboxEvent struct {
	ID          string          `json:"id"`
	Type        string          `json:"type"`
	AggregateID string          `json:"aggregate_id"`
	Payload     json.RawMessage `json:"payload"`
	Attempts    int             `json:"attempts"`
	CreatedAt   time.Time       `json:"created_at"`
}

type IncomingWhatsAppMessage struct {
	MessageID string
	From      string
	Body      string
	SentAt    time.Time
}

type WhatsAppStatus struct {
	MessageID string
	Status    string
	ErrorCode string
	ErrorText string
}

type ConversationInput struct {
	Conversation  Conversation
	Customer      CustomerSummary
	Booking       *BookingSummary
	Bookings      []BookingSummary
	Messages      []ConversationMessage
	BusinessInfo  BusinessInformation
	LatestMessage string
}

type ConversationResult struct {
	Reply         string
	Escalate      bool
	PendingAction *PendingAction
	ToolCalls     []AIToolCall
}

type PendingAction struct {
	Action    string          `json:"action"`
	BookingID string          `json:"booking_id,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

type AIToolCall struct {
	Name                 string          `json:"name"`
	Args                 json.RawMessage `json:"args,omitempty"`
	RequiresConfirmation bool            `json:"requires_confirmation"`
}

type MessagingClient interface {
	SendText(ctx context.Context, to string, message string) error
	SendTemplate(ctx context.Context, to string, template string, params map[string]string) error
}

type AIClient interface {
	ProcessConversation(ctx context.Context, input ConversationInput) (ConversationResult, error)
}

type Repository interface {
	ClaimPendingOutboxEvents(ctx context.Context, limit int) ([]OutboxEvent, error)
	MarkOutboxEventDone(ctx context.Context, eventID string) error
	MarkOutboxEventFailed(ctx context.Context, eventID string, reason string) error
	GetBooking(ctx context.Context, bookingID string) (*BookingSummary, error)
	GetCustomerByPhone(ctx context.Context, phone string) (*CustomerSummary, error)
	GetCustomerActiveBookings(ctx context.Context, customerID string) ([]BookingSummary, error)
	FindOrCreateConversation(ctx context.Context, customerID, bookingID, channel string) (*Conversation, error)
	GetConversation(ctx context.Context, conversationID string) (*Conversation, error)
	SetConversationStatus(ctx context.Context, conversationID, status string) error
	SetPendingAction(ctx context.Context, conversationID string, action *PendingAction) error
	RecentMessages(ctx context.Context, conversationID string, limit int) ([]ConversationMessage, error)
	SaveMessage(ctx context.Context, message ConversationMessage) (*ConversationMessage, error)
	HasExternalMessage(ctx context.Context, externalMessageID string) (bool, error)
	EnqueueIncomingWhatsApp(ctx context.Context, message IncomingWhatsAppMessage) error
	UpdateWhatsAppStatus(ctx context.Context, status WhatsAppStatus) error
	RecordAIAction(ctx context.Context, conversationID, customerID, bookingID, action string, args any, result any, status string) error
	GetBusinessInformation(ctx context.Context) (BusinessInformation, error)
	CheckAvailability(ctx context.Context, serviceID string, requestedTime time.Time) ([]AvailableSlot, error)
	RescheduleBooking(ctx context.Context, bookingID, slotID string) error
	CancelBooking(ctx context.Context, bookingID string) error
}
