package main

import (
	"flag"
	"fmt"
	"net"
	"strings"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggstack/src/types"
)

// Global configuration variables accessible by hooks
var (
	allowedIPsFlag   *string
	injectHttpHeader *bool
	allowedIPs       []*net.IPNet
)

// Setup custom command-line flags
func SetupPatchesFlags() {
	allowedIPsFlag = flag.String("allowed-ips", "", "comma-separated whitelist of incoming Yggdrasil IPv6 addresses/subnets allowed to connect to remote mappings")
	injectHttpHeader = flag.Bool("inject-http-header", false, "Inject X-Forwarded-For and X-Real-IP headers into incoming HTTP requests over TCP")
}

// Parse the flags into runtime configuration structures
func InitPatches() {
	if *allowedIPsFlag != "" {
		for _, item := range strings.Split(*allowedIPsFlag, ",") {
			item = strings.TrimSpace(item)
			if !strings.Contains(item, "/") {
				if strings.Contains(item, ":") {
					item += "/128"
				} else {
					item += "/32"
				}
			}
			_, ipNet, err := net.ParseCIDR(item)
			if err != nil {
				panic(fmt.Errorf("invalid allowed-ips entry %q: %w", item, err))
			}
			allowedIPs = append(allowedIPs, ipNet)
		}
	}
}

// Validate whether a remote network address matches the whitelist
func IsIPAllowed(remoteAddr net.Addr) bool {
	if len(allowedIPs) == 0 {
		return true
	}
	host, _, _ := net.SplitHostPort(remoteAddr.String())
	remoteIP := net.ParseIP(host)
	for _, ipNet := range allowedIPs {
		if ipNet.Contains(remoteIP) {
			return true
		}
	}
	return false
}

// Handle the whitelist evaluation and proxy the connection
func ProcessRemoteTCP(logger *log.Logger, mtu uint64, clientConn net.Conn, backendConn net.Conn) bool {
	if !IsIPAllowed(clientConn.RemoteAddr()) {
		host, _, _ := net.SplitHostPort(clientConn.RemoteAddr().String())
		logger.Warnf("Blocked unauthorized TCP connection from %s", host)
		_ = clientConn.Close()
		_ = backendConn.Close()
		return false
	}

	if *injectHttpHeader {
		go func() {
			buf := make([]byte, mtu)
			n, err := clientConn.Read(buf)
			if err != nil || n == 0 {
				_ = clientConn.Close()
				_ = backendConn.Close()
				return
			}

			payload := buf[:n]
			strPayload := string(payload)

			isHTTP := strings.HasPrefix(strPayload, "GET ") ||
				strings.HasPrefix(strPayload, "POST ") ||
				strings.HasPrefix(strPayload, "HEAD ") ||
				strings.HasPrefix(strPayload, "PUT ") ||
				strings.HasPrefix(strPayload, "DELETE ") ||
				strings.HasPrefix(strPayload, "OPTIONS ") ||
				strings.HasPrefix(strPayload, "PATCH ")

			if isHTTP {
				index := strings.Index(strPayload, "\r\n")
				if index != -1 {
					clientIP, _, _ := net.SplitHostPort(clientConn.RemoteAddr().String())
					headersToInject := fmt.Sprintf("\r\nX-Forwarded-For: %s\r\nX-Real-IP: %s", clientIP, clientIP)
					modifiedPayload := strPayload[:index] + headersToInject + strPayload[index:]
					payload = []byte(modifiedPayload)
				}
			}

			_, err = backendConn.Write(payload)
			if err != nil {
				_ = clientConn.Close()
				_ = backendConn.Close()
				return
			}

			_ = types.ProxyTCP(mtu, clientConn, backendConn)
		}()
	} else {
		go types.ProxyTCP(mtu, clientConn, backendConn)
	}

	return true
}
