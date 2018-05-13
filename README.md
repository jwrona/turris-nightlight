# turris-nightlight
Turris-nighlight is a program for the [Turris router](https://www.turris.cz) to set its LED intensity according the current time period (nighttime, morning twilight, daytime, evening twilight).
The intensity is set to the minimal value during nighttime, to the maximal value during daytime, gradually increased during morning twilight, and gradually decreased during evening twilight.

The start and end points of the mentioned time periods vary, based on factors such as season, latitude, longitude, and time zone.
Turris-nightlight uses a web API (http://api.sunrise-sunset.org/) to obtain these time points.
If geographic coordinates are not supplied as command-line arguments, the coordinates are obtained by an IP geolocation service.
A query to a web IP geolocation API (http://ip-api.com/line) will be performed, which will use your current IP address (as seen by the API).

## Usage
```Shell
turris-nightlight.sh --help
```

## Automatic Operation
Turris-nightlight sets the LED intensity according to the current time and exits.
In order to ensure convenient automatic operation, it is necessary to run it periodically.
One way to do this is to use cron with the following crontab file (/etc/cron.d/turris-nightlight):
```
MAILTO=""
*/1     *       *       *       *       root    turris-nightlight.sh --log syslog
```
This will run the turris-nightlight.sh script every minute and will log its output to syslog.
