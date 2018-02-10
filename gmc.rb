#!/usr/bin/env ruby

# --- configuration -----------------------------------------------------------

PORT="/dev/serial/by-id/usb-1a86_USB2.0-Serial-if00-port0"
SPEED=57600
TIMEOUT=0.3                             # short timeout for a read or write completion
MEMSIZE=65536                           # GMC 300E+ only has 64k internal buffer (~1017 minutes max logging)
EXTRAPAGE=1376                          # unmapped bytes at the end

OUTPUT='/tmp/gmc.png'                   # output graph via gnuplot, saved as png
OUTRAW=''                               # raw dump output file, empty string for no output

DEBUG=false

# --- library -----------------------------------------------------------------

require 'timeout'
require 'io/console'                    # this is required for iflush


def info str
  STDERR.puts str
end


def debug str
  info(str)  if DEBUG
end


class String                            # hexify string for screen output

  def as_hex
    str = ''
    each_byte do |i|
      str += "%02x " % [i]
    end
    str.strip
  end

  def as_timestamp
    t = unpack 'c6'                     # only consider 6 bytes: YYmmaaHHMMSS
    t[0] += 2000
    Time.mktime *t
  end

end


class File                              # add extras for the serial channel

  def cmd command, expectedbytes = 0    # send a command, return the answer
    str, out = command.upcase, ''
    8.times do                          # only 8 tries before giving up

      sleep 0.05                        # because sometimes command blast is not OK
      iflush

      begin
        Timeout.timeout(TIMEOUT) do
          debug "<#{str}>>"
          self.print "<#{str}>>"
        end
      rescue Timeout::Error             # expired timeout?
        debug "<<<<<ERR:1"
        next                            # just try again
      end
      debug "<...reading #{expectedbytes} bytes...>"
      if expectedbytes > 0
        begin
          Timeout.timeout(TIMEOUT) do
            out = self.read expectedbytes
            debug "<...OUT: #{out.inspect}"
          end
        rescue
          debug "<...OUT: read error>"
          next                          # read timeout? retry again
        end
      end
      #debug "<OUT: #{out.inspect}"
      return out                        # if no timeouts, deliver it
    end

    info "!--timeout error on #{command.inspect}, only read #{out.size}/#{expectedbytes} bytes"
    info(out.as_hex)  if out != ''
    exit 1
  end


  def mem start, len                    # baroque process to read+decode device "flash" memory data
    spir = "spir"
    spir += [ start ].pack('N')[1..-1]  # 24 bit big endian, 0 to MEMSIZE-1
    spir += [ len   ].pack('n')         # 16 bit big endian, 1 to 4096
    cmd spir, len
  end


  def getdate                           # get device date/time
    8.times do
      dat = cmd('getdatetime', 7)
      if dat[-1..-1] == 0xaa.chr
        if dat.as_hex[0..0] == '1'      # yikes: this doesn't work if year is not between 2016 and 2031
          return dat.as_timestamp
        end
      end
      sleep TIMEOUT                     # invalid date/time packet, just wait and retry
    end

    info "!--cannot get device date/time"
    exit 2
  end

end


# --- initialization ----------------------------------------------------------

if ARGV.size > 1 || (! [ nil, "alldata" ].include?(ARGV.first))
  info "!--usage: #{$0} [ alldata ]"
  exit 3
end

waitmsg = true
while ! File.readable? PORT             # wait until connected (aka: until port appears)
  info("!--waiting: #{PORT}")  if waitmsg
  waitmsg = false
  sleep 5
end

# required ugly hack to set and verify the serial port speed:
stty=`stty --file=#{PORT} #{SPEED} raw -echo < #{PORT}; stty --file=#{PORT} -a`

if stty[0..10] != "speed #{SPEED}"
  info "!--stty error: #{stty}"
  exit 4
end

fp = File.open(PORT, 'w+')
sleep 0.1
fp.iflush                               # discard unrequested data


# --- output some debug messages; watch out for garbage values ----------------

ver = fp.cmd('getver', 14)
if ver[0..4] != 'GMC-3'
  info "!--read error; reboot device and restart - #{ver.as_hex}"
  exit 5
end

bat = fp.cmd('getvolt',1)[0..0].ord     # assume 3.7V battery (old models have a 9V one)
if bat < 30 || bat > 45                 # whine if outside 3.0V and 4.5V
  info "!--battery voltage communication error (#{bat.as_hex}); reboot device and restart"
  exit 6
end

ignored = fp.mem(MEMSIZE, EXTRAPAGE)    # circumvent bizarre SPI-read bug

dat = fp.getdate
cfg = fp.cmd('getcfg',256)              # only 72 bytes used

debug "!--version: #{ver}"
debug "!--battery: #{bat/10.0} V"
debug "!--serial#: #{fp.cmd('getserial', 7).as_hex}"
debug "!--date:    #{dat}"
debug "!--config:  #{cfg[0..72].as_hex}"


# --- read the raw 64k data from its circular buffer in the device eeprom -----

debug "!--reading: "
buf, addr, step = '', 0, 256
while addr < MEMSIZE
  buf += fp.mem addr, step
  addr += step
  STDERR.print '.'
  STDERR.flush
end
debug 'OK'


# --- parse raw buffer while sanitizing data and ignoring garbage -------------

db = []                                 # timestamped readings
buf += buf[0..11]                       # added for index safety
ts = nil                                # logged timestamp
i = -1                                  # current index

while true                              # loop: extract unordered data
  i += 1
  break  if i >= MEMSIZE
  val = buf[i].ord                      # fetch next byte

  if val != 0x55                        # click count presumed?
    ts = nil  if val == 0xff            # trash timestamp if uninitialized values
    next  unless ts                     # skip useless value if no timestamp
    db << [ ts, val ]                   # store reasonably timestamped values
    ts += 1
    next
  end
    
  if buf[i+1].ord == 0xaa               # new timestamp incoming?
    i += 1  if buf[i+3] == buf[i+4]     # fix possible hiccup
    begin
      ts = buf[i+3..i+10].as_timestamp  # try to update timestamp for next values
      debug "!--timesync #{ts} from offset #{i}"
    rescue
      debug "!--garbage: invalid timestamp at offset #{i}"
      ts = nil                          # garbage found, ignore data until next valid timestamp
    end
    i += 10                             # skip timestamp packet
    next
  end

  db << [ ts, val ]                     # should never happen: store this scaring 0x55 CPS reading
  ts += 1
end

db.sort!.uniq! { |elem| elem.first }    # sort by timestamp deleting possible duplicates

val = db.collect { |i| i.last }

# -- since we can't erase eeprom data, by default we will only output today's records
# (except if "alldata" option was requested):
#
if ARGV.first != "alldata"
  t = Time.now
  today = Time.mktime t.year, t.month, t.day
  db.delete_if { |elem| elem.first < today }
end

if db.size == 0
  info "!--no data available"
  exit 0
end


# --- output some statistics --------------------------------------------------

from = db.first.first
to = db.last.first
max = val.max
info "!--samples: #{db.size}"
info "!--from:    #{from}"
info "!--to:      #{to}"

(0..255).each do |i|
  x = val.count i
  next  if x == 0
  p = x * 1000 / val.size
  info "!--values:  #{i}:\t#{x}\t#{p/10}.#{p%10}%"
end

total = 0
db.each do |elem|
  cps = elem.last
  total += cps
  next  if cps < 6
  info "!--highest: #{elem.first}: #{cps}"
end
debug "!--#{total} total clicks"


# --- dump --------------------------------------------------------------------

if OUTRAW != ''
  File.open(OUTRAW, 'w').print buf      # save a copy of the 64k binary buffer
end

#db.each do |elem|                      # dump a readable text
#  puts "#{elem.first.strftime '%Y%m%d.%H%M%S: '} #{elem.last}"
#end

debug "!--output:  #{OUTPUT}"
fp = IO.popen 'gnuplot', 'w'            # dump to a gnuplot image
fp.puts "
set output   '#{OUTPUT}'
set terminal png large size 1280,720
set xdata    time
set timefmt  '%Y%m%d.%H%M%S:'
set format x '%H:%M'
set yrange   [-0.5 : 24]
set encoding utf8
set label    \"#{from.strftime 'from %Y-%m-%d %H:%M:%S'}\"         at '#{db.first.first.strftime '%Y%m%d.%H%M%S:'}', 23.1
set label    \"#{to.strftime 'to   %Y-%m-%d %H:%M:%S'}\"           at '#{db.first.first.strftime '%Y%m%d.%H%M%S:'}', 22.4
set label    \"#{db.size} reads, #{total} clicks, highest: #{max}\" at '#{db.first.first.strftime '%Y%m%d.%H%M%S:'}', 21.7
set grid
plot '-' using 1:2 title 'CPS (clicks per second)' with impulse"

db.each do |elem|
  fp.puts "#{elem.first.strftime '%Y%m%d.%H%M%S '} #{elem.last}"
end
fp.puts "eof"

