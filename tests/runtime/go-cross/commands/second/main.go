package main

import (
	"fmt"
	"runtime"

	"example.org/spartan/greeting"
)

func main() {
	fmt.Println("second command:", greeting.Message(), runtime.GOOS+"/"+runtime.GOARCH)
}
