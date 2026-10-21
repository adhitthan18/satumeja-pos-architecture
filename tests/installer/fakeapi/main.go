// fakeapi stands in for the real API in the installer tests: it only needs
// to start, listen on the port the installer probes, and answer /readyz.
package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8090"
	}
	http.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	log.Fatal(http.ListenAndServe(addr, nil))
}
