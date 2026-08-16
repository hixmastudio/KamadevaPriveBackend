package domain

import (
	"encoding/json"
	"strconv"
	"strings"
)

type SambaTicketRange struct {
	From    string              `json:"from"`
	To      string              `json:"to"`
	Count   int                 `json:"count"`
	Tickets []SambaSourceTicket `json:"tickets"`
}

type SambaCleanTicketQuery struct {
	From string
	To   string
	Page int
}

type SambaSourceHealth struct {
	OK       bool   `json:"ok"`
	Samba    string `json:"samba"`
	Site     string `json:"site"`
	Database string `json:"database"`
	Server   string `json:"server"`
}

type SambaSourceTicket struct {
	ID                   int64                    `json:"id"`
	TicketNumber         string                   `json:"ticketNumber"`
	TicketUID            string                   `json:"ticketUid"`
	Date                 string                   `json:"date"`
	LastOrderDate        string                   `json:"lastOrderDate"`
	LastPaymentDate      string                   `json:"lastPaymentDate"`
	IsClosed             bool                     `json:"isClosed"`
	RemainingAmount      float64                  `json:"remainingAmount"`
	TotalAmount          float64                  `json:"totalAmount"`
	TotalAmountPreTax    float64                  `json:"totalAmountPreTax"`
	DepartmentName       string                   `json:"departmentName"`
	CreatedUserName      string                   `json:"createdUserName"`
	LastModifiedUserName string                   `json:"lastModifiedUserName"`
	TicketTags           string                   `json:"ticketTags"`
	TicketStates         []map[string]any         `json:"ticketStates"`
	Orders               []SambaSourceOrder       `json:"orders"`
	Payments             []SambaSourcePayment     `json:"payments"`
	Calculations         []SambaSourceCalculation `json:"calculations"`
	Entities             []SambaSourceEntity      `json:"entities"`
}

type SambaSourceOrder struct {
	MenuItemName   string           `json:"menuItemName"`
	PortionName    string           `json:"portionName"`
	Price          float64          `json:"price"`
	Quantity       float64          `json:"quantity"`
	CalculatePrice bool             `json:"calculatePrice"`
	OrderStates    []map[string]any `json:"orderStates"`
}

type SambaSourcePayment struct {
	PaymentTypeName string  `json:"paymentTypeName"`
	PaymentName     string  `json:"paymentName"`
	Amount          float64 `json:"amount"`
	TenderedAmount  float64 `json:"tenderedAmount"`
	Date            string  `json:"date"`
	UserID          int64   `json:"userId"`
	TicketNumber    string  `json:"ticketNumber"`
}

type SambaSourceCalculation struct {
	Name              string      `json:"name"`
	Amount            SambaNumber `json:"amount"`
	CalculationAmount SambaNumber `json:"calculationAmount"`
	DecreaseAmount    SambaNumber `json:"decreaseAmount"`
	IncludeTax        bool        `json:"includeTax"`
}

type SambaSourceEntity struct {
	EntityID       int64  `json:"entityId"`
	EntityName     string `json:"entityName"`
	EntityTypeName string `json:"entityTypeName"`
	Notes          string `json:"notes"`
}

type SambaNumber float64

func (n *SambaNumber) UnmarshalJSON(raw []byte) error {
	value := strings.TrimSpace(string(raw))
	if value == "" || value == "null" || value == "false" {
		*n = 0
		return nil
	}
	if value == "true" {
		*n = 1
		return nil
	}
	var number float64
	if err := json.Unmarshal(raw, &number); err == nil {
		*n = SambaNumber(number)
		return nil
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		parsed, parseErr := strconv.ParseFloat(strings.TrimSpace(text), 64)
		if parseErr != nil {
			*n = 0
			return nil
		}
		*n = SambaNumber(parsed)
		return nil
	}
	*n = 0
	return nil
}

func (n SambaNumber) Float64() float64 {
	return float64(n)
}
