package capabilities

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/aquasecurity/tracee/pkg/logger"
	"kernel.org/pub/linux/libs/security/libcap/cap"
)

var Caps Capabilities // singleton for all packages

const pkgName = "capabilities"

//
// "Effective" might be at protection rings 0,1,2,3
// "Permitted" is always at ring0 (so effective can migrate rings)
// "Bound" will bet set to unprivileged so exec() can't inherit capabilities.
//

type ringType int

const (
	Privileged   ringType = iota // ring0 (all capabilities enabled, startup/shutdown)
	Required                     // ring1 (needed capabilities only: config time)
	Requested                    // ring2 (temporary specific capabilities)
	Unprivileged                 // ring3 (no capabilities: runtime)
)

type Capabilities struct {
	have        *cap.Set
	all         map[cap.Value]map[ringType]bool
	bypass      bool
	initialized bool
	lock        *sync.Mutex // big lock to guarantee all threads are on the same ring
}

func NewCapabilities(bypass bool) error {
	Caps = Capabilities{}
	return Caps.initialize(bypass)
}

func (c *Capabilities) initialize(bypass bool) error {
	if bypass {
		c.bypass = true
		return nil
	}
	if c.initialized {
		return alreadyInitialized()
	}

	c.lock = new(sync.Mutex)
	c.all = make(map[cap.Value]map[ringType]bool)

	for v := cap.Value(0); v < cap.MaxBits(); v++ {
		c.all[v] = make(map[ringType]bool)
		c.all[v][Privileged] = true // all capabilities are enabled
		// Required, Requested and Unprivileged is false by default
	}

	err := c.getProc()
	if err != nil {
		return err
	}

	for c := range c.all {
		cap.DropBound(c) // drop all capabilities from bound
	}

	err = c.setProc()
	if err != nil {
		return err
	}

	// The base for required capabilities (ring1) depends on the following:

	c.Require(
		cap.IPC_LOCK,
		cap.SYS_RESOURCE,
	)

	// Kernels bellow v5.8 do not support cap.BPF + cap.PERFMON (instead of
	// having to have cap.SYS_ADMIN), nevertheless, some kernels, like RHEL8
	// clones, have backported cap.BPF capability and might be able to use it.

	paranoid, err := getKernelPerfEventParanoidValue()
	if err != nil {
		logger.Debug("could not get perf_event_paranoid, assuming highest", "pkg", pkgName)
	}

	if paranoid > 2 {
		logger.Debug("paranoid: Value in /proc/sys/kernel/perf_event_paranoid is > 2", "pkg", pkgName)
		logger.Debug("paranoid: Tracee needs CAP_SYS_ADMIN instead of CAP_BPF + CAP_PERFMON", "pkg", pkgName)
		logger.Debug("paranoid: To change that behavior set perf_event_paranoid to 2 or less.", "pkg", pkgName)
		c.Require(cap.SYS_ADMIN)
	}

	hasBPF, _ := c.have.GetFlag(cap.Permitted, cap.BPF)
	if hasBPF {
		c.Require(
			cap.BPF,
			cap.PERFMON,
		)
	} else {
		c.Require(
			cap.SYS_ADMIN,
		)
	}

	return c.apply(Unprivileged) // ring3 as effective
}

// Public Methods

// Privileged is a protection ring with all caps set as Effective.
func (c *Capabilities) Privileged(cb func() error) error {
	var err error

	if !c.bypass {
		c.lock.Lock()
		defer c.lock.Unlock()

		err = c.apply(Privileged) // ring0 as effective for callback exec
		if err != nil {
			return err
		}
	}

	errCb := cb() // callback

	if !c.bypass {
		err = c.apply(Unprivileged) // back to ring3
		if err != nil {
			return err
		}
	}

	return errCb
}

// Required is a protection ring with only the required caps set as Effective.
func (c *Capabilities) Required(cb func() error) error {
	var err error

	if !c.bypass {
		c.lock.Lock()
		defer c.lock.Unlock()

		err = c.apply(Required) // ring1 as effective
		if err != nil {
			return err
		}
	}

	errCb := cb() // callback

	if !c.bypass {
		err = c.apply(Unprivileged) // back to ring3
		if err != nil {
			return err
		}
	}

	return errCb
}

// Requested is a protection ring that needs configuration each time it is
// called. Instead of making Required capabilities Effective, like Required(),
// it sets as Effective only given capabilities, for a single time, until the
// next ring is called. It is specially needed for startup/shutdown actions that
// might require specific capabilities Effective.
func (c *Capabilities) Requested(cb func() error, values ...cap.Value) error {
	var err error

	if !c.bypass {
		c.lock.Lock()
		defer c.lock.Unlock()

		err = c.set(Requested, values...)
		if err != nil {
			return err
		}
		err = c.apply(Requested) // ring2 as effective
		if err != nil {
			return err
		}
		err = c.unset(Requested, values...) // clean requested (for next calls)
		if err != nil {
			return err
		}
	}

	errCb := cb()

	if !c.bypass {
		err := c.apply(Unprivileged)
		if err != nil {
			return err
		}
	}

	return errCb
}

// setters/getters

// Require is called after initialization, configures all required capabilities,
// and those required capabilities are set as Effective each time Required() is
// called.
func (c *Capabilities) Require(values ...cap.Value) error {
	var err error

	if c.bypass {
		return nil
	}

	c.lock.Lock()                    // do not change caps while in a protective ring
	err = c.set(Required, values...) // populate ring1 (Required)
	c.lock.Unlock()

	return err
}

// Unrequire is only called when command line "capabilities drop=X" is given.
// It works by removing, from the required ring, the capabilities given by the
// user. This way, when tracee shifts to ring1 (Required), that capability won't
// be Effective.
func (c *Capabilities) Unrequire(values ...cap.Value) error {
	var err error

	if c.bypass {
		return nil
	}

	c.lock.Lock()                      // do not change caps while in an protective ring
	err = c.unset(Required, values...) // unpopulate ring1 (Required)
	c.lock.Unlock()

	return err
}

// Private Methods

func (c *Capabilities) getProc() error {
	var err error

	c.have, err = cap.GetPID(0)
	if err != nil {
		return couldNotGetProc(err)
	}

	return nil
}

func (c *Capabilities) setProc() error {
	err := c.have.SetProc()
	if err != nil {
		return couldNotSetProc(err)
	}

	return nil
}

func (c *Capabilities) set(t ringType, values ...cap.Value) error {
	for _, v := range values {
		c.all[v][t] = true
	}

	return nil
}

func (c *Capabilities) unset(t ringType, values ...cap.Value) error {
	for _, v := range values {
		c.all[v][t] = false
	}

	return nil
}

func (c *Capabilities) apply(t ringType) error {
	var err error

	err = c.getProc()
	if err != nil {
		return err
	}

	logger.Debug("capabilities change", "pkg", pkgName)

	for k, v := range c.all {
		if v[t] {
			logger.Debug("enabling", "pkg", pkgName, "cap", k)
		}
		err = c.have.SetFlag(cap.Effective, v[t], k)
		if err != nil {
			return err
		}
	}

	return c.setProc()
}

//
// Error Functions
//

func couldNotFindCapability(cap string) error {
	return fmt.Errorf("could not find capability: %v", cap)
}

func couldNotReadPerfEventParanoid() error {
	return fmt.Errorf("could not read procfs perf_event_paranoid")
}

func couldNotSetProc(e error) error {
	return fmt.Errorf("could not set capabilities: %v", e)
}

func couldNotGetProc(e error) error {
	return fmt.Errorf("could not get capabilities: %v", e)
}

func alreadyInitialized() error {
	return fmt.Errorf("capabilities were already initialized")
}

//
// Standalone Functions
//

func ReqByString(values ...string) ([]cap.Value, error) {
	var found bool
	var capsToActOn []cap.Value

	for _, given := range values {
		found = false
		for v := cap.Value(0); v < cap.MaxBits(); v++ {
			if v.String() == given {
				capsToActOn = append(capsToActOn, v)
				found = true
			}
		}
		if !found {
			return nil, couldNotFindCapability(given)
		}
	}

	return capsToActOn, nil
}

// ListAvailCaps lists available capabilities in the running environment
func ListAvailCaps() []string {
	var availCaps []string

	for v := cap.Value(0); v < cap.MaxBits(); v++ {
		availCaps = append(availCaps, v.String())
	}

	return availCaps
}

// getKernelPerfEventParanoidValue retrieves the value of the kernel parameter
// perf_event_paranoid
func getKernelPerfEventParanoidValue() (int, error) {
	// perf event paranoia level:
	//
	// -1 = not paranoid at all
	//  0 = disallow raw tracepoint access for unpriv
	//  1 = disallow cpu events for unpriv
	//  2 = disallow kernel profiling for unpriv
	//  4 = disallow all unpriv perf event use (not in all distros)
	//
	const MaxParanoiaLevel = 4

	value, err := os.ReadFile("/proc/sys/kernel/perf_event_paranoid")
	if err != nil {
		return MaxParanoiaLevel, couldNotReadPerfEventParanoid()
	}

	intVal, err := strconv.ParseInt(strings.TrimSuffix(string(value), "\n"), 0, 16)
	if err != nil {
		return MaxParanoiaLevel, couldNotReadPerfEventParanoid()
	}

	return int(intVal), nil
}