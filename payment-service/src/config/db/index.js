const { ObjectId } = require('mongodb')
const { connect, close } = require('./mongo')

module.exports = {
  connect,
  close,
  ObjectId
}