'use strict'
const status = require('http-status')

module.exports = ({repo}, app) => {

  app.post('/notification/sendEmail', (req, res, next) => {
    const {validate} = req.container.cradle

    validate(req.body.payload, 'notification')
      .then(payload => {
        return repo.sendEmail(payload)
      })
      .then(ok => {
        res.status(status.OK).json({msg: 'ok'})
      })
      .catch(next)
  })

  app.post('/notification/sendSMS', (req, res, next) => {
    const {validate} = req.container.cradle

    validate(req.body.payload, 'notification')
      .then(payload => {
        return repo.sendSMS(payload)
      })
      .then(ok => {
        res.status(status.OK).json({msg: 'ok'})
      })
      .catch(next)
  })

  app.get('/notifications', (req, res, next) => {
    const filters = {}
    
    // Filtri opzionali
    if (req.query.type) filters.type = req.query.type
    if (req.query.status) filters.status = req.query.status
    if (req.query.recipient) filters.recipient = new RegExp(req.query.recipient, 'i')
    
    repo.getNotifications(filters)
      .then(notifications => {
        res.status(status.OK).json(notifications)
      })
      .catch(next)
  })

  app.get('/notifications/:id', (req, res, next) => {
    const filters = { _id: req.params.id }
    
    repo.getNotifications(filters)
      .then(notifications => {
        if (notifications.length === 0) {
          return res.status(status.NOT_FOUND).json({ error: 'Notification not found' })
        }
        res.status(status.OK).json(notifications[0])
      })
      .catch(next)
  })
}
