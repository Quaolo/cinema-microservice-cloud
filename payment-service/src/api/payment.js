'use strict'
const status = require('http-status')

module.exports = ({repo}, app) => {

  app.post('/payment/makePurchase', (req, res, next) => {
    const {validate} = req.container.cradle

    validate(req.body.paymentOrder, 'payment')
      .then(payment => {
        return repo.registerPurchase(payment)
      })
      .then(paid => {
        res.status(status.OK).json({paid})
      })
      .catch(next)
  })

  app.get('/payment/getPurchaseById/:id', (req, res, next) => {
    repo.getPurchaseById(req.params.id)
      .then(payment => {
        res.status(status.OK).json({payment})
      })
      .catch(next)
  })

  app.get('/payments', (req, res, next) => {
    const filters = {}
    
    // Filtri opzionali
    if (req.query.status) filters.status = req.query.status
    if (req.query.userName) filters.userName = new RegExp(req.query.userName, 'i')
    if (req.query.currency) filters.currency = req.query.currency
    
    repo.getPayments(filters)
      .then(payments => {
        res.status(status.OK).json(payments)
      })
      .catch(next)
  })

  app.get('/payments/:id', (req, res, next) => {
    const filters = { _id: req.params.id }
    
    repo.getPayments(filters)
      .then(payments => {
        if (payments.length === 0) {
          return res.status(status.NOT_FOUND).json({ error: 'Payment not found' })
        }
        res.status(status.OK).json(payments[0])
      })
      .catch(next)
  })
}
