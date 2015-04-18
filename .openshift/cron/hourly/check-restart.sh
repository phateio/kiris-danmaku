if [ "`curl -s http://$OPENSHIFT_NODEJS_IP:$OPENSHIFT_NODEJS_PORT/`" == "" ]; then
  echo 1 | gear restart
  echo 2 | gear restart
fi
