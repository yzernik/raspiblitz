#!/bin/bash

## get basic info
source /home/admin/raspiblitz.info
source /mnt/hdd/raspiblitz.conf 

# CHECK #########

echo "*** Check Basic Config ***"
if [ ${#network} -eq 0 ]; then
  echo "FAIL - missing: network"
  exit 1
fi
if [ ${#chain} -eq 0 ]; then
  echo "FAIL - missing: chain"
  exit 1
fi

# CHECK #########

echo "*** Check ${network} Running ***"
bitcoinRunning=$(systemctl status ${network}d.service 2>/dev/null | grep -c running)
if [ ${bitcoinRunning} -eq 0 ]; then
  bitcoinRunning=$(sudo -u bitcoin ${network}-cli -datadir=/home/bitcoin/.${network} getblockchaininfo  | grep -c verificationprogress)
fi
if [ ${bitcoinRunning} -eq 0 ]; then 
  whiptail --title "70initLND - WARNING" --yes-button "Retry" --no-button "EXIT+Logs" --yesno "Service ${network}d is not running." 8 50
  if [ $? -eq 0 ]; then
    /home/admin/70initLND.sh
  else
    /home/admin/XXdebugLogs.sh
  fi
  exit 1
fi

# CHECK #########

echo "*** Check ${network} Responding ***"
chainIsReady=0
loopCount=0
while [ ${chainIsReady} -eq 0 ]
  do
    loopCount=$(($loopCount +1))
    result=$(sudo -u bitcoin ${network}-cli -datadir=/home/bitcoin/.${network} getblockchaininfo 2>error.out)
    error=`cat error.out`
    rm error.out
    if [ ${#error} -gt 0 ]; then
      if [ ${loopCount} -gt 33 ]; then
        echo "*** TAKES LONGER THEN EXCEPTED ***"
        date +%s
        echo "result(${result})"
        echo "error(${error})"
        testnetAdd=""
        if [ "${chain}"  = "test" ]; then
         testnetAdd="testnet3/"
        fi
        sudo tail -n 5 /mnt/hdd/${network}/${testnetAdd}debug.log
        echo "If you see an error -28 relax, just give it some time."
        echo "Waiting 1 minute and then trying again ..."
        sleep 60
      else
        echo "(${loopCount}/33) still waiting .."
        sleep 10
      fi
    else
      echo "OK - chainnetwork is working"
      echo ""
      chainIsReady=1
      break
    fi
  done

# CHECK #########

echo "*** Check LND Config ***"
configExists=$( sudo ls /mnt/hdd/lnd/lnd.conf 2>/dev/null | grep -c lnd.conf )
if [ ${configExists} -eq 0 ]; then
  sudo cp /home/admin/assets/lnd.${network}.conf /mnt/hdd/lnd/lnd.conf
  source <(sudo cat /mnt/hdd/${network}/${network}.conf 2>/dev/null | grep "rpcpassword" | sed 's/^[a-z]*\./lnd/g')
  sudo sed -i "s/^${network}d.rpcpass=.*/${network}d.rpcpass=${rpcpassword}/g" /mnt/hdd/lnd/lnd.conf
  sudo chown bitcoin:bitcoin /mnt/hdd/lnd/lnd.conf
  if [ -d /home/bitcoin/.lnd ]; then
    echo "OK - LND config written"
  else
    echo "FAIL - Was not able to setup LND"
    exit 1
  fi
else
  echo "OK - exists"
fi
echo ""

###### Start LND

echo "*** Starting LND ***"
lndRunning=$(sudo systemctl status lnd.service 2>/dev/null | grep -c running)
if [ ${lndRunning} -eq 0 ]; then
  sudo systemctl stop lnd 2>/dev/null
  sudo systemctl disable lnd 2>/dev/null
  sed -i "5s/.*/Wants=${network}d.service/" /home/admin/assets/lnd.service
  sed -i "6s/.*/After=${network}d.service/" /home/admin/assets/lnd.service
  sudo cp /home/admin/assets/lnd.service /etc/systemd/system/lnd.service
  sudo chmod +x /etc/systemd/system/lnd.service
  sudo systemctl enable lnd
  sudo systemctl start lnd
  echo ""
  dialog --pause "  Starting LND - please wait .." 8 58 120
fi

###### Check LND starting

while [ ${lndRunning} -eq 0 ]
do
  lndRunning=$(sudo systemctl status lnd.service | grep -c running)
  if [ ${lndRunning} -eq 0 ]; then
    date +%s
    echo "LND not ready yet ... waiting another 60 seconds."
    echo "If this takes too long (more then 10min total) --> CTRL+c and report Problem"
    sleep 60
  fi
done
echo "OK - LND is running"
echo ""

###### Check LND health/fails (to be extended)
fail=""
tlsExists=$(sudo ls /mnt/hdd/lnd/tls.cert 2>/dev/null | grep -c "tls.cert")
if [ ${tlsExists} -eq 0 ]; then
  fail="LND was starting, but missing /mnt/hdd/lnd/tls.cert"
fi
if [ ${#fail} -gt 0 ]; then
  whiptail --title "70initLND - WARNING" --yes-button "Retry" --no-button "EXIT+Logs" --yesno "${fail}" 8 50
  if [ $? -eq 0 ]; then
    /home/admin/70initLND.sh
  else
    /home/admin/XXdebugLogs.sh
  fi
  exit 1
fi

###### Instructions on Creating/Restoring LND Wallet
walletExists=$(sudo ls /mnt/hdd/lnd/data/chain/${network}/${chain}net/wallet.db 2>/dev/null | grep wallet.db -c)
echo "walletExists(${walletExists})"
sleep 2
if [ ${walletExists} -eq 0 ]; then

  # UI: Ask if user wants NEW wallet or RECOVER a wallet
  OPTIONS=(NEW "Setup a brand new Lightning Node (DEFAULT)" \
           OLD "I had a old Node I want to recover/restore")
  CHOICE=$(dialog --backtitle "RaspiBlitz" --clear --title "LND Setup" --menu "LND Data & Wallet" 11 60 6 "${OPTIONS[@]}" 2>&1 >/dev/tty)
  echo "choice($CHOICE)"

  if [ "${CHOICE}" == "NEW" ]; then

############################
# NEW WALLET
############################

    # let user enter password c
    sudo shred /home/admin/.pass.tmp 2>/dev/null
    sudo /home/admin/config.scripts/blitz.setpassword.sh x "Set your Password C for the LND Wallet Unlock" /home/admin/.pass.tmp
    passwordC=`sudo cat /home/admin/.pass.tmp`
    sudo shred /home/admin/.pass.tmp 2>/dev/null

    # make sure passwordC is set
    if [ ${#passwordC} -eq 0 ]; then
      /home/admin/70initLND.sh
      exit 1
    fi

    # generate wallet with seed and set passwordC
    echo "Generating new Wallet ...."
    source /home/admin/python-env-lnd/bin/activate
    python /home/admin/config.scripts/lnd.initwallet.py new ${passwordC} > /home/admin/.seed.tmp
    source /home/admin/.seed.tmp
    sudo shred /home/admin/.pass.tmp 2>/dev/null

    # in case of error - retry
    if [ ${#err} -gt 0 ]; then
      whiptail --title "lnd.initwallet.py - ERROR" --msgbox "${err}" 8 50
      /home/admin/70initLND.sh
      exit 1
    else
      if [ ${#seedwords} -eq 0 ]; then
        echo "FAIL!! -> MISSING seedwords data - but also no err data ?!?"
        echo "CHECK output data above - PRESS ENTER to restart 70initLND.sh" 
        read key
        /home/admin/70initLND.sh
        exit 1
      fi
    fi

    if [ ${#seedwords6x4} -eq 0 ]; then
      seedwords6x4="${seedwords}"
    fi

    ack=0
    while [ ${ack} -eq 0 ]
    do
      whiptail --title "IMPORTANT SEED WORDS - PLEASE WRITE DOWN" --msgbox "LND Wallet got created. Store these numbered words in a safe location:\n\n${seedwords6x4}" 12 76
      whiptail --title "Please Confirm" --yes-button "Show Again" --no-button "CONTINUE" --yesno "  Are you sure that you wrote down the word list?" 8 55
      if [ $? -eq 1 ]; then
        ack=1
      fi
    done

    sudo sed -i "s/^setupStep=.*/setupStep=65/g" /home/admin/raspiblitz.info

  else

############################
# RECOVER OLD WALLET
############################

    OPTIONS=(LNDRESCUE "LND tar.gz-Backupfile (BEST)" \
             SEED+SCB "Seed & channel.backup file (OK)" \
             ONLYSEED "Only Seed Word List (FALLBACK)")
    CHOICE=$(dialog --backtitle "RaspiBlitz" --clear --title "RECOVER LND DATA & WALLET" --menu "Data you have to recover from?" 11 60 6 "${OPTIONS[@]}" 2>&1 >/dev/tty)

    # LND RESCUE
    if [ "${CHOICE}" == "LNDRESCUE" ]; then
      sudo /home/admin/config.scripts/lnd.rescue.sh restore
      echo ""
      echo "PRESS ENTER to continue."
      read key
      /home/admin/70initLND.sh
      exit 1
    fi

    # WARNING ON ONLY SEED
    if [ "${CHOICE}" == "ONLYSEED" ]; then
      whiptail --title "IMPORTANT INFO" --yes-button "Continue" --no-button "Go Back" --yesno "
Using JUST SEED WORDS will only recover your on-chain funds.
To also try to recover the open channel funds you need the
channel.backup file (since RaspiBlitz v1.2 / LND 0.6-beta)
or having a complete LND rescue-backup from your old node.
      " 11 65
      if [ $? -eq 1 ]; then
        /home/admin/70initLND.sh
        exit 1
      fi
    fi

    # IF SEED and SCB - make user upload channel.backup file now
    # and it will get automated activated after syns are ready
    # TODO: later activate directly with call to lnd.iniwallet.py
    if [ "${CHOICE}" == "SEED+SCB" ]; then

      # let lnd.rescue script do the upload process
      /home/admin/config.scripts/lnd.rescue.sh scb-up

      # check exit code of script
      if [ $? -eq 1 ]; then
        echo "USER CANCEL --> back to menu"
        /home/admin/70initLND.sh
        exit 1
      else
        clear
        echo "FILE UPLOADED --> will get checked/activated after blockchain/lightning is synced"
      fi
    fi

    clear

    # let user enter password c
    sudo shred /home/admin/.pass.tmp 2>/dev/null
    sudo /home/admin/config.scripts/blitz.setpassword.sh x "Set your Password C for the LND Wallet Unlock" /home/admin/.pass.tmp
    passwordC=`sudo cat /home/admin/.pass.tmp`
    sudo shred /home/admin/.pass.tmp 2>/dev/null

    # get seed word list
    if [ "${CHOICE}" == "SEED+SCB" ] || [ "${CHOICE}" == "ONLYSEED" ]; then

      wordsCorrect=0
      while [ ${wordsCorrect} -eq 0 ]
      do
        # dialog to enter
        dialog --backtitle "RaspiBlitz - LND Recover" --inputbox "Please enter/paste the SEED WORD LIST:\n(just the words, seperated by spaces, in correct order as numbered)" 9 78 2>/home/admin/.seed.tmp
        wordstring=$( cat /home/admin/.seed.tmp | sed 's/[^a-zA-Z0-9,]//g' )
        shred /home/admin/.seed.tmp
        echo "processing ... ${wordstring}"

        # check correct number of words
        wordcount=$(echo "${wordstring}" | wc -w)
        if [ ${wordcount} -eq 24 ]; then
          echo "OK - 24 words"
          wordsCorrect=1
        else
          whiptail --title " WARNING " \
			    --yes-button "Try Again" \
		      --no-button "Cancel" \
		      --yesno "
The word list has ${wordcount} words. But it must be 24.
Please check your list and try again.

Best is to write words in external editor 
and then copy and paste them into dialog.

The Word list should look like this:
wordone wordtweo wordthree ...

" 16 52

	        if [ $? -eq 1 ]; then
            /home/admin/70initLND.sh
            exit 1
	        fi
        fi
      done

      # ask if seed was protected by password D
      passwordD=""
      dialog --title "SEED PASSWORD" --yes-button "No extra Password" --no-button "Yes" --yesno "
Are your seed words protected by an extra password?

During wallet creation LND offers to set an extra password
to protect the seed words. Most users did not set this.
      " 11 65
      if [ $? -eq 1 ]; then
        sudo shred /home/admin/.pass.tmp 2>/dev/null
        sudo /home/admin/config.scripts/blitz.setpassword.sh x "Enter extra Password D" /home/admin/.pass.tmp
        passwordD=`sudo cat /home/admin/.pass.tmp`
        sudo shred /home/admin/.pass.tmp 2>/dev/null
      fi

    fi

    # FOR NOW: let channel.backup file get activated by lncli after syncs
    # LATER: make different call to lnd.initwallet.py
    if [ "${CHOICE}" == "SEED+SCB" ] || [ "${CHOICE}" == "ONLYSEED" ]; then

      # trigger wallet recovery
      source <(python /home/admin/config.scripts/lnd.initwallet.py seed ${passwordC} ${wordstring} ${passwordD})

      # check if wallet was created for real
      if [ ${#err} -eq 0 ]; then
        walletExists=$(sudo ls /mnt/hdd/lnd/data/chain/${network}/${chain}net/wallet.db 2>/dev/null | grep wallet.db -c)
        if [ ${walletExists} -eq 0 ]; then
          err="Was not able to create wallet (unknown error)."
        fi
      fi

      # user feedback
      if [ ${#err} -eq 0 ]; then
        dialog --title " SUCCESS " --msgbox "
Looks good :) LND was able to recover the wallet.
      " 7 53
      else
        whiptail --title " FAIL " --msgbox "
Something went wrong - see info below:
${err}
${errMore}
      " 13 72
          /home/admin/70initLND.sh
          exit 1
      fi
    fi

##### FALLBACK UNTIL config.scripts/lnd.initwallet.py WORKS
#    echo "****************************************************************************"
#    echo "* RECOVER LND WALLET BY SEED WORDS"
#    echo "****************************************************************************"
#    echo "A) For 'Wallet Password' use your old PASSWORD C"
#    echo "B) For 'cipher seed mnemonic' answere 'y' and then enter your seed words" 
#    echo "C) On 'cipher seed passphrase' ONLY enter PASSWORD D if u used it on create"
#    echo "D) On 'address look-ahead' only enter more than 2500 had lots of channels"
#    echo "****************************************************************************"
#    echo ""
#    sudo -u bitcoin /usr/local/bin/lncli --chain=${network} --network=${chain}net create 2>/home/admin/.error.tmp
#    error=`cat /home/admin/.error.tmp`
#    rm /home/admin/.error.tmp 2>/dev/null
#
#    if [ ${#error} -gt 0 ]; then
#      echo ""
#      echo "!!! FAIL !!! SOMETHING WENT WRONG:"
#      echo "${error}"
#      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
#      echo ""
#      echo "Press ENTER to retry ..."
#      read key
#      echo "Starting RETRY ..."
#      /home/admin/70initLND.sh
#      exit 1
#    fi

    /home/admin/70initLND.sh

  fi # END OLD WALLET

else
  echo "OK - LND wallet already exists."
fi

dialog --pause "  Waiting for LND - please wait .." 8 58 60

############################
# Copy LND macaroons to admin
############################

echo ""
echo "*** Copy LND Macaroons to user admin ***"
macaroonExists=$(sudo -u bitcoin ls -la /home/bitcoin/.lnd/data/chain/${network}/${chain}net/admin.macaroon 2>/dev/null | grep -c admin.macaroon)
if [ ${macaroonExists} -eq 0 ]; then
  /home/admin/AAunlockLND.sh
  sleep 3
fi
macaroonExists=$(sudo -u bitcoin ls -la /home/bitcoin/.lnd/data/chain/${network}/${chain}net/admin.macaroon 2>/dev/null | grep -c admin.macaroon)
if [ ${macaroonExists} -eq 0 ]; then
  sudo -u bitcoin ls -la /home/bitcoin/.lnd/data/chain/${network}/${chain}net/admin.macaroon
  echo ""
  echo "FAIL - LND Macaroons not created"
  echo "Please check the following LND issue:"
  echo "https://github.com/lightningnetwork/lnd/issues/890"
  echo "You may want try again with starting ./70initLND.sh"
  exit 1
fi
macaroonExists=$(sudo ls -la /home/admin/.lnd/data/chain/${network}/${chain}net/ | grep -c admin.macaroon)
if [ ${macaroonExists} -eq 0 ]; then
  sudo mkdir /home/admin/.lnd
  sudo mkdir /home/admin/.lnd/data
  sudo mkdir /home/admin/.lnd/data/chain
  sudo mkdir /home/admin/.lnd/data/chain/${network}
  sudo mkdir /home/admin/.lnd/data/chain/${network}/${chain}net
  sudo cp /home/bitcoin/.lnd/tls.cert /home/admin/.lnd
  sudo cp /home/bitcoin/.lnd/lnd.conf /home/admin/.lnd
  sudo cp /home/bitcoin/.lnd/data/chain/${network}/${chain}net/admin.macaroon /home/admin/.lnd/data/chain/${network}/${chain}net
  sudo chown -R admin:admin /home/admin/.lnd/
  echo "OK - LND Macaroons created"
  echo ""
else
  echo "OK - Macaroons are already copied"
  echo ""
fi

###### Unlock Wallet (if needed)
echo "*** Check Wallet Lock ***"
locked=$(sudo tail -n 1 /mnt/hdd/lnd/logs/${network}/${chain}net/lnd.log | grep -c unlock)
if [ ${locked} -gt 0 ]; then
  echo "OK - Wallet is locked ... starting unlocking dialog"
  /home/admin/AAunlockLND.sh
else
  echo "OK - Wallet is already unlocked"
fi
echo ""

# set SetupState (scan is done - so its 80%)
sudo sed -i "s/^setupStep=.*/setupStep=80/g" /home/admin/raspiblitz.info

###### finishSetup
sudo /home/admin/90finishSetup.sh
sudo /home/admin/95finalSetup.sh