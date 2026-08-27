package main

// multipart.go — reading a multipart FILE PART the way the product does, which
// is NOT the way Go's mime/multipart does.
//
// MEASURED E2E on 2026-08-27 (G5 Task 10, écart É1), by capturing the request
// Ansible actually puts on the wire:
//
//	Content-Transfer-Encoding: base64
//	Content-Type: application/zip
//	Content-Disposition: form-data; name="file"; filename="archive.zip"
//	first 24 bytes -> b'UEsDBBQAAAAIAER4G1269dPk'   (i.e. base64 of "PK\x03\x04…")
//
// `ansible.builtin.uri` with body_format: form-multipart BASE64-ENCODES a binary
// part and announces it with Content-Transfer-Encoding. Go's mime/multipart
// deliberately ignores that header (it is not part of the HTML form spec), so a
// handler reading the part gets base64 TEXT: the mock answered
// `not a zip: zip: not a valid zip file` while the same bytes sent by curl
// imported fine — and the promotion role, the CLIENT-FACING engine, could not
// deploy into any mock tier of the lab.
//
// The real 10.15 decodes it (INFERRED, not measured: the Ansible engine's
// promotion gate is green against the real gateway, which is only possible if
// the product honours the header). The mock therefore honours it too — that is
// the point of a stand-in. Any other value (7bit / 8bit / binary / absent) means
// the body IS the payload, unchanged.

import (
	"encoding/base64"
	"fmt"
	"io"
	"mime/multipart"
	"strings"
)

// readPart returns the bytes a multipart file part CARRIES, decoding the body
// when the part announces Content-Transfer-Encoding: base64.
func readPart(file io.Reader, fh *multipart.FileHeader) ([]byte, error) {
	raw, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	cte := ""
	if fh != nil {
		cte = strings.TrimSpace(fh.Header.Get("Content-Transfer-Encoding"))
	}
	if !strings.EqualFold(cte, "base64") {
		return raw, nil
	}
	// MIME base64 may be line-wrapped (RFC 2045 caps lines at 76 chars) and Go's
	// decoder refuses the newlines, so strip ASCII whitespace first.
	decoded, err := base64.StdEncoding.DecodeString(stripASCIIWhitespace(string(raw)))
	if err != nil {
		return nil, fmt.Errorf("part announces Content-Transfer-Encoding: base64 but its body does not decode: %w", err)
	}
	return decoded, nil
}

// stripASCIIWhitespace drops CR, LF, tabs and spaces — the only characters a
// wrapped base64 body adds.
func stripASCIIWhitespace(s string) string {
	return strings.Map(func(r rune) rune {
		switch r {
		case '\r', '\n', '\t', ' ':
			return -1
		}
		return r
	}, s)
}
