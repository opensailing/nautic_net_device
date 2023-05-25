#
# Configuration for testing the app in local development (not on-device).
#
import Config

# Don't start these servers for testing; we will supervise them manually
# in the test cases
config :nautic_net_device, NauticNet.CAN, false
config :nautic_net_device, NauticNet.Discovery, false
