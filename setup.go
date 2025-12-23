package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"

	_ "embed"

	"github.com/abenz1267/elephant/v2/pkg/common"
	"github.com/abenz1267/elephant/v2/pkg/pb/pb"
	"google.golang.org/protobuf/proto"
)

var (
	Name       = "numr"
	NamePretty = "Numr Calculator"
	config     *Config

	// Cache for async updates
	cacheMu     sync.Mutex
	cachedItem  *pb.QueryResponse_Item
	cachedQuery string
)

const QueryAsyncItem = 1

// sendAsyncUpdate sends an async update to Walker
func sendAsyncUpdate(format uint8, query string, conn net.Conn, item *pb.QueryResponse_Item) {
	req := pb.QueryResponse{
		Query: query,
		Item:  item,
	}

	var b []byte
	var err error

	switch format {
	case 0:
		b, err = proto.Marshal(&req)
	case 1:
		b, err = json.Marshal(&req)
	}

	if err != nil {
		slog.Debug(Name, "async marshal", err)
		return
	}

	var buffer bytes.Buffer
	buffer.Write([]byte{QueryAsyncItem})

	lengthBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lengthBuf, uint32(len(b)))
	buffer.Write(lengthBuf)
	buffer.Write(b)

	_, err = conn.Write(buffer.Bytes())
	if err != nil {
		slog.Debug(Name, "async write", err)
	}
}

//go:embed README.md
var readme string

const (
	ActionCopy    = "copy"
	ActionRefresh = "refresh"
	ActionAppend  = "append"
)

type Config struct {
	common.Config `koanf:",squash"`
	RequireNumber bool   `koanf:"require_number" desc:"require number in query" default:"true"`
	MinChars      int    `koanf:"min_chars" desc:"minimum query length" default:"2"`
	Command       string `koanf:"command" desc:"copy command (%VALUE% replaced)" default:"wl-copy -n %VALUE%"`
}

// NumrRequest is the JSON-RPC request to numr-cli
type NumrRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	Method  string      `json:"method"`
	Params  NumrParams  `json:"params"`
	ID      int         `json:"id"`
}

type NumrParams struct {
	Expr string `json:"expr"`
}

// NumrResponse is the JSON-RPC response from numr-cli
type NumrResponse struct {
	JSONRPC string     `json:"jsonrpc"`
	Result  NumrResult `json:"result"`
	ID      int        `json:"id"`
}

type NumrResult struct {
	Display string `json:"display"`
	Type    string `json:"type"`
	Value   string `json:"value"`
	Unit    string `json:"unit,omitempty"`
}

// RatesCache represents the rates.json structure
type RatesCache struct {
	Timestamp int64 `json:"timestamp"`
}

// getRatesUpdateTime returns human-readable time since rates were updated
func getRatesUpdateTime() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	ratesPath := filepath.Join(home, ".config", "numr", "rates.json")
	data, err := os.ReadFile(ratesPath)
	if err != nil {
		return ""
	}

	var cache RatesCache
	if err := json.Unmarshal(data, &cache); err != nil {
		return ""
	}

	updateTime := time.Unix(cache.Timestamp, 0)
	duration := time.Since(updateTime)

	if duration < time.Hour {
		return fmt.Sprintf("rates updated %dm ago", int(duration.Minutes()))
	} else if duration < 24*time.Hour {
		return fmt.Sprintf("rates updated %dh ago", int(duration.Hours()))
	} else {
		days := int(duration.Hours() / 24)
		return fmt.Sprintf("rates updated %dd ago", days)
	}
}

func Setup() {
	config = &Config{
		Config: common.Config{
			Icon: "accessories-calculator",
		},
		RequireNumber: true,
		MinChars:      2,
		Command:       "wl-copy -n %VALUE%",
	}

	common.LoadConfig(Name, config)

	if config.NamePretty != "" {
		NamePretty = config.NamePretty
	}
}

func Available() bool {
	p, err := exec.LookPath("numr-cli")
	if p == "" || err != nil {
		slog.Info(Name, "available", "numr-cli not found. disabling")
		return false
	}
	return true
}

func PrintDoc() {
	fmt.Println(readme)
	fmt.Println()
}

func couldBeCalc(query string) bool {
	if query == "" {
		return false
	}

	hasNumber := false
	for _, c := range query {
		if unicode.IsDigit(c) {
			hasNumber = true
			break
		}
	}
	if !hasNumber {
		return false
	}

	// Check for math operators
	if strings.ContainsAny(query, "+-*/^%") {
		return true
	}

	// Check for unit conversion patterns
	if strings.Contains(query, " to ") || strings.Contains(query, " in ") || strings.Contains(query, " of ") {
		return true
	}

	// Check for number followed by space/letters (e.g., "100 km", "5m")
	runes := []rune(query)
	for i, c := range runes {
		if unicode.IsDigit(c) && i < len(runes)-1 {
			next := runes[i+1]
			if unicode.IsSpace(next) || unicode.IsLetter(next) {
				return true
			}
		}
	}

	return false
}

// refreshRates calls numr-cli to fetch fresh exchange rates
func refreshRates() {
	req := NumrRequest{
		JSONRPC: "2.0",
		Method:  "reload_rates",
		ID:      1,
	}

	reqJSON, err := json.Marshal(req)
	if err != nil {
		slog.Error(Name, "refresh_rates marshal", err)
		return
	}

	cmd := exec.Command("numr-cli", "--server")
	cmd.Stdin = strings.NewReader(string(reqJSON))

	out, err := cmd.Output()
	if err != nil {
		slog.Error(Name, "refresh_rates", err)
		return
	}

	slog.Info(Name, "refresh_rates", string(out))
}

func evalNumr(query string) (*NumrResult, error) {
	req := NumrRequest{
		JSONRPC: "2.0",
		Method:  "eval",
		Params:  NumrParams{Expr: query},
		ID:      1,
	}

	reqJSON, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	cmd := exec.Command("numr-cli", "--server")
	cmd.Stdin = strings.NewReader(string(reqJSON))

	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var resp NumrResponse
	if err := json.Unmarshal(out, &resp); err != nil {
		return nil, err
	}

	return &resp.Result, nil
}

// buildResultItem creates a QueryResponse_Item from a numr result
func buildResultItem(query string, result *NumrResult) *pb.QueryResponse_Item {
	resultDisplay := result.Display
	state := []string{result.Type}

	// Format result with unit/currency
	if result.Unit != "" && result.Value != "" {
		resultDisplay = fmt.Sprintf("%s %s", result.Value, result.Unit)
	}

	// For currency, add rates info under expression
	exprDisplay := query
	if result.Type == "currency" {
		if ratesInfo := getRatesUpdateTime(); ratesInfo != "" {
			exprDisplay = fmt.Sprintf("%s\n%s", query, ratesInfo)
		}
	}

	return &pb.QueryResponse_Item{
		Identifier: "numr-calc-result",
		Text:       exprDisplay,
		Icon:       config.Icon,
		Subtext:    resultDisplay,
		Provider:   Name,
		Score:      1000,
		Type:       pb.QueryResponse_REGULAR,
		Actions:    []string{ActionCopy, ActionRefresh, ActionAppend},
		State:      state,
	}
}

func Activate(single bool, identifier, action string, query string, args string, format uint8, conn net.Conn) {
	switch action {
	case ActionRefresh:
		refreshRates()

		result, err := evalNumr(query)
		if err != nil {
			slog.Error(Name, "eval after refresh", err)
			return
		}

		sendAsyncUpdate(format, query, conn, buildResultItem(query, result))

	case ActionCopy:
		result, err := evalNumr(query)
		if err != nil {
			slog.Error(Name, "eval", err)
			return
		}

		value := result.Value
		if value == "" {
			value = result.Display
		}

		cmd := common.ReplaceResultOrStdinCmd(config.Command, value)
		err = cmd.Start()
		if err != nil {
			slog.Error(Name, "copy", err)
		} else {
			go func() {
				cmd.Wait()
			}()
		}

	case ActionAppend:
		// Append expression to ~/.config/numr/default.numr
		home, err := os.UserHomeDir()
		if err != nil {
			slog.Error(Name, "append home", err)
			return
		}

		numrFile := filepath.Join(home, ".config", "numr", "default.numr")

		// Create directory if needed
		if err := os.MkdirAll(filepath.Dir(numrFile), 0755); err != nil {
			slog.Error(Name, "append mkdir", err)
			return
		}

		// Check if file needs a leading newline
		prefix := ""
		if data, err := os.ReadFile(numrFile); err == nil && len(data) > 0 {
			if data[len(data)-1] != '\n' {
				prefix = "\n"
			}
		}

		// Append expression with newline
		f, err := os.OpenFile(numrFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			slog.Error(Name, "append open", err)
			return
		}
		defer f.Close()

		if _, err := f.WriteString(prefix + query + "\n"); err != nil {
			slog.Error(Name, "append write", err)
		}

	default:
		slog.Error(Name, "activate", fmt.Sprintf("unknown action: %s", action))
	}
}

func Query(conn net.Conn, query string, single bool, _ bool, format uint8) []*pb.QueryResponse_Item {
	// Early exit for empty/short queries
	if query == "" || len(query) < config.MinChars {
		return []*pb.QueryResponse_Item{}
	}

	if config.RequireNumber && !couldBeCalc(query) {
		return []*pb.QueryResponse_Item{}
	}

	// Check if we have a cached result to return immediately
	cacheMu.Lock()
	cached := cachedItem
	cacheValid := cached != nil && (strings.HasPrefix(query, cachedQuery) || strings.HasPrefix(cachedQuery, query))
	cacheMu.Unlock()

	// Start async evaluation
	go func() {
		result, err := evalNumr(query)
		if err != nil {
			slog.Debug(Name, "eval", err)
			return
		}

		if result.Type == "error" || result.Type == "empty" || result.Display == "" {
			return
		}

		// Don't show if result equals input
		cleanDisplay := strings.ReplaceAll(result.Display, " ", "")
		cleanQuery := strings.ReplaceAll(query, " ", "")
		if cleanDisplay == cleanQuery {
			return
		}

		item := buildResultItem(query, result)

		// Update cache
		cacheMu.Lock()
		cachedItem = item
		cachedQuery = query
		cacheMu.Unlock()

		sendAsyncUpdate(format, query, conn, item)
	}()

	// Return cached result immediately if valid
	if cacheValid {
		return []*pb.QueryResponse_Item{cached}
	}

	return []*pb.QueryResponse_Item{}
}

func Icon() string {
	return config.Icon
}

func HideFromProviderlist() bool {
	return config.HideFromProviderlist
}

func State(provider string) *pb.ProviderStateResponse {
	return &pb.ProviderStateResponse{}
}
