package gxutil

import (
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"

	sh "github.com/dms3-fs/go-fs-api"
	homedir "github.com/mitchellh/go-homedir"
	ma "github.com/dms3-mft/go-multiaddr"
	manet "github.com/dms3-mft/go-multiaddr-net"
	log "github.com/whyrusleeping/stump"
)

var UsingGateway bool

func NewShell() *sh.Shell {
	if apivar := os.Getenv("DMS3FS_API"); apivar != "" {
		log.VLog("using '%s' from DMS3FS_API env as api endpoint.", apivar)
		return sh.NewShell(apivar)
	}

	ash, err := getLocalAPIShell()
	if err == nil {
		return ash
	}

	UsingGateway = true

	log.VLog("using global dms3fs gateways as api endpoint")
	return sh.NewShell("https://dms3.io")
}

func getLocalAPIShell() (*sh.Shell, error) {
	ipath := os.Getenv("DMS3FS_PATH")
	if ipath == "" {
		home, err := homedir.Dir()
		if err != nil {
			return nil, err
		}

		ipath = filepath.Join(home, ".dms3-fs")
	}

	apifile := filepath.Join(ipath, "api")

	data, err := ioutil.ReadFile(apifile)
	if err != nil {
		return nil, err
	}

	addr := strings.Trim(string(data), "\n\t ")

	host, err := multiaddrToNormal(addr)
	if err != nil {
		return nil, err
	}

	local := sh.NewShell(host)

	_, _, err = local.Version()
	if err != nil {
		return nil, err
	}

	return local, nil
}

func multiaddrToNormal(addr string) (string, error) {
	maddr, err := ma.NewMultiaddr(addr)
	if err != nil {
		return "", err
	}

	_, host, err := manet.DialArgs(maddr)
	if err != nil {
		return "", err
	}

	return host, nil
}
