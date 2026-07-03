# syntax=docker/dockerfile:1
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/wm-trace-bridge .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/wm-trace-bridge /wm-trace-bridge
EXPOSE 9100
ENTRYPOINT ["/wm-trace-bridge"]
