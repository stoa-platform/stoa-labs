# syntax=docker/dockerfile:1
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/wso2-otel-tap .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/wso2-otel-tap /wso2-otel-tap
EXPOSE 4317
ENTRYPOINT ["/wso2-otel-tap"]
