package main

import (
	"reflect"
	"testing"
)

func TestSyntheticParsesHosts(t *testing.T) {
	got := parseHosts(" dev.localtest.me, prod.localtest.me ,,initech.localtest.me ")
	want := []string{"dev.localtest.me", "prod.localtest.me", "initech.localtest.me"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseHosts = %q, want %q", got, want)
	}
	if len(parseHosts("")) != 0 {
		t.Fatal("empty HOSTS should give no targets")
	}
}
