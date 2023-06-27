# SmartThings-RainMachine-Edge
SmartThings/RainMachine Integration via Edge

This provides an integration between SmartThings and RainMachine using a LAN Edge driver. This a direct connection between the hub and the RM controller (no bridge server needed).

![Zone](https://i.imgur.com/Ioq6q87l.png "Zone") ![Program](https://i.imgur.com/NdBs7i1l.png "Program")


## Installation
  - Add the Edge driver to your SmartThings hub - [click here to add the driver channel](https://bestow-regional.api.smartthings.com/invite/BxlrLZK3GxMP)
    ![Driver](https://i.imgur.com/aDBWYTql.png "Driver")
  - Open the SmartThings mobile app.
  - Go to devices and click the add button to Add device.
  - Scan for nearby devices
  - You should see the RainMachine Controller device added. This can take up to 30 seconds. If it still does not show up, go back out to the "No room assigned" category and see if it got added to the bottom.
![Scan](https://i.imgur.com/B5cDeevl.png "Scan")
  - Go to the RainMachine controller device, tap the elipses at the top right, then tap settings
  - Enter the IP, port, and password of your RainMachine controller
  - Upon saving, the SmartThings hub will try to find your controller, login, and automatically create devices.
  - If something goes wrong, refresh the controller device and check the status field.

## Donate/Sponsor:

If you love this integration, feel free to donate or check out the GitHub Sponsor program.

| Platform        | Wallet/Link | QR Code  |
|------------- |-------------|------|
| GitHub Sponsorship      | https://github.com/sponsors/brbeaird |  |
| Paypal      | [![PayPal - The safer, easier way to give online!](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif "Donate")](https://www.paypal.com/donate/?hosted_button_id=9LVBCJK5KDUSA) |

