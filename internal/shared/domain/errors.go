package domain

import "fmt"

type AppError struct {
	Status  int
	Code    string
	Message string
	Details any
}

func (e *AppError) Error() string {
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func Unauthorized() *AppError {
	return &AppError{Status: 401, Code: "unauthorized", Message: "Unauthorized."}
}

func ValidationError(details any) *AppError {
	return &AppError{Status: 400, Code: "validation_error", Message: "Invalid request payload.", Details: details}
}

func UpstreamError(message string, details any) *AppError {
	return &AppError{Status: 502, Code: "upstream_error", Message: message, Details: details}
}

func Forbidden(message string) *AppError {
	return &AppError{Status: 403, Code: "forbidden", Message: message}
}

func NotFound(message string) *AppError {
	return &AppError{Status: 404, Code: "not_found", Message: message}
}
