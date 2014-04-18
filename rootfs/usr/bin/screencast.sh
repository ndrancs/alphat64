#!/bin/sh -a
# Screencast Creator v1.2
# Copyright (C) 2010 - James Budiono
# License: GPL vesion 3 - see http://www.gnu.org/licenses/gpl.html
# uses: gtkdialog, Xdialog, ffmpeg
# update 1.1 - make it compatible with ffmpeg 0.9.1 in Fatdog64 600
# update 1.2 - update defaults with more sensible values - tested with vlc 2.01 and ffmpeg 0.11.1

#xrandr | 
#sed -n '/Screen/ {s/.*current \(.* x .*\),.*/\1/; s/\([0-9]*\) x \([0-9]*\)/\1 \2/p}' | 
#while read HORZ VERT
#do
#	echo $HORZ
#	echo $VERT
#done

# constant definitions - these are modifiable through Advanced Options
APPTITLE="Screencast Creator"
APPVERSION=1.2
PAUSE_FLAG=/tmp/x-pauseflag-x
PREPARE_TIME=10
AUDIO_DEVICE=hw:0,0
AUDIO_CHANNEL=2
FRAME_RATE=16
DEFAULT_OUT_FILE=/tmp/out

# variable definitions
FFMPEG_PID=
FFMPEG_ARGS=

SCREEN_RES=
QUALITY=
FORMAT=
TARGET_RES=
VIDEO_CODEC=
VIDEO_BITRATE=
VIDEO_BIT_TOLERANCE=
VIDEO_OPTION=
AUDIO_CODEC=
AUDIO_BITRATE=
AUDIO_SAMPLERATE=


# function definitions
function get_screen_resolution() {
	read HORZ VERT <<EOF
		$(xrandr | sed -n '/Screen/ {s/.*current \(.* x .*\),.*/\1/; s/\([0-9]*\) x \([0-9]*\)/\1 \2/p}')
EOF
	SCREEN_RES=${HORZ}x${VERT}
}

function get_half_resolution() {
	local tgt_horz
	tgt_horz=$(($HORZ/2))
	[ $(($tgt_horz % 2)) -eq 1 ] && tgt_horz=$(( tgt_horz + 1))
	TARGET_RES=$(($tgt_horz))x$(($VERT/2))
	
}

function get_quarter_resolution() {
	local tgt_horz
	tgt_horz=$(($HORZ/4))
	[ $(($tgt_horz % 2)) -eq 1 ] && tgt_horz=$(( tgt_horz + 1))	
	TARGET_RES=$(($tgt_horz))x$(($VERT/4))
}

function show_about() {
	Xdialog -title About --msgbox "${APPTITLE} v${APPVERSION}\n(C) James Budiono 2010, 2012." 0 0
}

# show recording options
function show_options_gui() {
	GUI=$(cat <<EOV|sed "s/#.*//" # enable interpolation and comments
	<window title="${APPTITLE}">
		<notebook labels="Recording Settings|Advanced Options">

			# Settings dialog
			<vbox>
				<frame Instructions>
					<text use-markup="true" xalign="0">
						<label>
"The application will wait for <b>10 seconds</b> after you click the Record button before starting to record. 
When finished, you can stop recording anytime by clicking the Stop button on upper-left hand corner."
						</label>
					</text>
				</frame>

				<frame Output filename>
					<hbox>
						<entry accept="savefilename">
							<label>Select a Filename</label>
							<variable>FILE_SAVEFILENAME</variable>
							<input>echo $DEFAULT_OUT_FILE</input>
						</entry>
						<button>
							<input file stock="gtk-open"></input>
							<variable>FILE_BROWSE_SAVEFILENAME</variable>
							<action type="fileselect">FILE_SAVEFILENAME</action>
						</button>
					</hbox>
					<checkbox>
						<label>"Record sound"</label>
						<variable>RECORD_AUDIO</variable>
						<default>true</default>
					</checkbox>			
				</frame>

				<frame Choose resolution>
						<radiobutton>
							<variable>RES_QUARTER</variable>
							<label>"Quarter screen"</label>
						</radiobutton>
						<radiobutton>
							<variable>RES_HALF</variable>
							<label>"Half screen"</label>
							<default>true</default>
						</radiobutton>
						<radiobutton>
							<variable>RES_FULL</variable>
							<label>"Full screen"</label>
						</radiobutton>
				</frame>
				
				<frame Choose quality>
						<radiobutton>
							<variable>QUALITY_LOW</variable>
							<label>"Low quality (small file size)"</label>
						</radiobutton>
						<radiobutton>
							<variable>QUALITY_MED</variable>
							<label>"Medium quality (medium file size)"</label>
							<default>true</default>
						</radiobutton>
						<radiobutton>
							<variable>QUALITY_HIGH</variable>
							<label>"High quality (large file size)"</label>
						</radiobutton>
				</frame>
				
				<frame Choose format>
						<radiobutton>
							<variable>FORMAT_MP4</variable>
							<label>"Linux (MP4) - smaller file size"</label>
							<default>true</default>
						</radiobutton>
						<radiobutton>
							<variable>FORMAT_AVI</variable>
							<label>"Windows compatilble (AVI) best for Avidemux."</label>
						</radiobutton>
				</frame>
				
				<hbox>
					<button>
						<variable>ABOUT_BUTTON</variable>
						<input file stock="gtk-about"></input>
						<label>About</label>
						<action>show_about</action>				
					</button>			
					<button cancel></button>
					<button>
						<variable>RECORD_BUTTON</variable>
						<input file stock="gtk-media-record"></input>
						<label>Start Recording</label>
						<action type="exit">record</action>				
					</button>
				</hbox>
			</vbox>
			
			# Advanced options dialog
			<vbox>
				<hbox>
					<text><label>Number of seconds to wait before starting to record</label></text>
					<entry>
						<variable>PREPARE_TIME</variable>
						<input>echo $PREPARE_TIME</input>
					</entry>	
				</hbox>
				<hbox>
					<text><label>Video frame rate</label></text>
					<entry>
						<variable>FRAME_RATE</variable>
						<input>echo $FRAME_RATE</input>
					</entry>	
				</hbox>	
				<hbox>
					<text><label>Audio device for recording</label></text>
					<entry>
						<variable>AUDIO_DEVICE</variable>
						<input>echo $AUDIO_DEVICE</input>
					</entry>				
				</hbox>
				<hbox>
					<text><label>Number of audio channels</label></text>
					<entry>
						<variable>AUDIO_CHANNEL</variable>
						<input>echo $AUDIO_CHANNEL</input>
					</entry>	
				</hbox>	
			</vbox>
		</notebook>
	</window>

EOV
	);
	
	OUT="$(gtkdialog --program=GUI)"
	#echo $OUT
	eval "$OUT"
}

function show_record_gui() {
	rm $PAUSE_FLAG
	GUI='
	<window title="Capturing">
		<vbox>
			<frame Status>
				<text>
					<input>if [ -f $PAUSE_FLAG ]; then echo Paused...; else echo Recording in progress ...; fi</input>
					<variable>INFO_TEXT</variable>
				</text>
			</frame>				
			<hbox>
				<button>
					<variable>PAUSE_BUTTON</variable>
					<input file stock="gtk-media-pause"></input>
					<label>Pause</label>
					<action>pause_recording</action>
					<action type="refresh">INFO_TEXT</action>
				</button>
				<button>
					<variable>STOP_BUTTON</variable>
					<input file stock="gtk-media-stop"></input>
					<label>Finish</label>
				</button>			
			</hbox>
		</vbox>
	</window>
'
	gtkdialog --program=GUI -G +0+0
}

function checkfile_exist() {
	if [ -f "$FILE_SAVEFILENAME" ]; then
		if ! Xdialog --title WARNING --yesno "$FILE_SAVEFILENAME already exist.\nAre you sure you want to overwrite?" 0 0; then
			exit
		fi
	fi

	if [ "$FILE_SAVEFILENAME" = $DEFAULT_OUT_FILE ]; then
		FILE_SAVEFILENAME=${DEFAULT_OUT_FILE}.${FORMAT}
	fi
}

function parse_options() {
	# 1. get the target resolution
	get_screen_resolution
	if [ $RES_FULL = "true" ]; then
		TARGET_RES=$SCREEN_RES
	elif [ $RES_HALF = "true" ]; then
		get_half_resolution
	elif [ $RES_QUARTER = "true" ]; then
		get_quarter_resolution
	fi
	
	# 2. format
	if [ $FORMAT_AVI = "true" ]; then 	
		FORMAT=avi
	elif [ $FORMAT_MP4 = "true" ]; then 
		FORMAT=mp4; 
	fi 

	# 3. quality
	if [ $QUALITY_LOW = "true" ]; then
		QUALITY=low
	elif [ $QUALITY_MED = "true" ]; then
		QUALITY=med
	elif [ $QUALITY_HIGH = "true" ]; then
		QUALITY=high
	fi	

	# 4. combination of quality and format
	case $FORMAT in
		mp4)
			VIDEO_CODEC=libx264
			AUDIO_CODEC=libfaac
			case $QUALITY in
				low)
					AUDIO_BITRATE=4k
					AUDIO_SAMPLERATE=11025
					VIDEO_BITRATE=16k
					VIDEO_BIT_TOLERANCE=16k
					VIDEO_OPTION="-preset slow -force_fps "
				;;
				med)
					AUDIO_BITRATE=4k
					AUDIO_SAMPLERATE=11025
					VIDEO_BITRATE=32k
					VIDEO_BIT_TOLERANCE=32k
					VIDEO_OPTION="-preset slow -force_fps "
				;;
				high)
					AUDIO_BITRATE=8k
					AUDIO_SAMPLERATE=22050
					VIDEO_BITRATE=128k
					VIDEO_BIT_TOLERANCE=128k
					VIDEO_OPTION="-preset slow -force_fps "
				;;
			esac
		;;
		avi)
			VIDEO_CODEC=wmv1 #edit from wmv2
			AUDIO_CODEC=libmp3lame
			case $QUALITY in
				low)
					AUDIO_BITRATE=8k
					AUDIO_SAMPLERATE=11025
					VIDEO_BITRATE=32k
					VIDEO_BIT_TOLERANCE=32k
				;;
				med)
					AUDIO_BITRATE=8k
					AUDIO_SAMPLERATE=11025
					VIDEO_BITRATE=64k
					VIDEO_BIT_TOLERANCE=64k
				;;
				high)
					AUDIO_BITRATE=16k
					AUDIO_SAMPLERATE=22050
					VIDEO_BITRATE=128k
					VIDEO_BIT_TOLERANCE=128k
				;;
			esac
		;;
	esac
	
	# 5. build the commandline to be passed
	FFMPEG_ARGS="-y -f x11grab -s $SCREEN_RES -r $FRAME_RATE -i $DISPLAY"
	if [ $RECORD_AUDIO = "true" ]; then
		FFMPEG_ARGS="${FFMPEG_ARGS} -f alsa -ac $AUDIO_CHANNEL -ar $AUDIO_SAMPLERATE -i $AUDIO_DEVICE -isync -acodec $AUDIO_CODEC -ab $AUDIO_BITRATE"
	fi
	FFMPEG_ARGS="${FFMPEG_ARGS} -r $FRAME_RATE -vcodec $VIDEO_CODEC -s $TARGET_RES -b:v $VIDEO_BITRATE -bt $VIDEO_BIT_TOLERANCE $VIDEO_OPTION -f $FORMAT "
	
	#echo "$FFMPEG_ARGS"
}

function start_recording() {
	sleep $PREPARE_TIME  # wait a while to let user prepare
	parse_options
	checkfile_exist

	# all set, now go !
	ffmpeg $FFMPEG_ARGS "$FILE_SAVEFILENAME" &
	FFMPEG_PID=$!
	
	# wait for 1 seconds, see if it is successful
	sleep 1
	if ! stat /proc/$FFMPEG_PID > /dev/null; then
		Xdialog --title ERROR --msgbox "Screen capture failed.\nRun $0 from terminal to see the error messages." 0 0
		exit
	fi
}

function pause_recording() {
	if [ -f $PAUSE_FLAG ]; then
		# currently pausing, reactivate
		kill -CONT $FFMPEG_PID
		rm $PAUSE_FLAG
	else
		# currently recording, pause now
		kill -TSTP $FFMPEG_PID
		touch $PAUSE_FLAG
	fi
}

function finish_recording() {
	kill -INT $FFMPEG_PID
}

# ==== main ====

show_options_gui;
if [ $EXIT = "record" ]; then
	start_recording
	show_record_gui
	finish_recording
	Xdialog --title "Screencast" --msgbox "Done! Screencast is saved in:\n$FILE_SAVEFILENAME" 0 0
fi
