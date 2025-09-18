'use strict'
const mongoose = require('mongoose')

// Schema per i pagamenti
const paymentSchema = new mongoose.Schema({
  userName: { type: String, required: true },
  amount: { type: Number, required: true },
  currency: { type: String, required: true },
  description: String,
  stripeChargeId: String,
  status: { 
    type: String, 
    enum: ['pending', 'completed', 'failed', 'refunded'], 
    default: 'pending' 
  },
  stripeResponse: {
    id: String,
    amount: Number,
    currency: String,
    status: String,
    paid: Boolean,
    created: Number,
    failure_code: String,
    failure_message: String,
    refunded: Boolean,
    refunds: {
      data: [{
        id: String,
        amount: Number,
        reason: String
      }]
    }
  }
}, { collection: 'payments', timestamps: true })

const Payment = mongoose.model('Payment', paymentSchema)

const repository = () => {
  const makePurchase = (payment) => {
    return new Promise((resolve, reject) => {
      // Stripe configuration - in production this should come from environment variables
      const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY || 'sk_test_...')
      
      // Crea record di pagamento
      const paymentRecord = new Payment({
        userName: payment.userName,
        amount: payment.amount,
        currency: payment.currency,
        description: payment.description,
        status: 'pending'
      })

      // Salva il pagamento prima di processare
      paymentRecord.save()
        .then(() => {
          stripe.charges.create({
            amount: Math.ceil(payment.amount * 100),
            currency: payment.currency,
            source: {
              number: payment.number,
              cvc: payment.cvc,
              exp_month: payment.exp_month,
              exp_year: payment.exp_year
            },
            description: payment.description
          }, (err, charge) => {
            if (err && err.type === 'StripeCardError') {
              // Aggiorna lo status a failed
              paymentRecord.status = 'failed'
              paymentRecord.stripeResponse = {
                id: charge?.id || null,
                amount: Math.ceil(payment.amount * 100),
                currency: payment.currency,
                status: 'failed',
                paid: false,
                failure_code: err.code,
                failure_message: err.message
              }
              paymentRecord.save()
              reject(new Error('An error occuered procesing payment with stripe, err: ' + err))
            } else {
              // Aggiorna lo status a completed
              paymentRecord.status = 'completed'
              paymentRecord.stripeChargeId = charge.id
              paymentRecord.stripeResponse = {
                id: charge.id,
                amount: charge.amount,
                currency: charge.currency,
                status: charge.status,
                paid: charge.paid,
                created: charge.created
              }
              paymentRecord.save()
              
              const paid = Object.assign({}, {user: payment.userName, amount: payment.amount, charge})
              resolve(paid)
            }
          })
        })
        .catch(err => {
          reject(new Error('An error occured saving payment, err:' + err))
        })
    })
  }

  const registerPurchase = (payment) => {
    return new Promise((resolve, reject) => {
      makePurchase(payment)
        .then(paid => {
          // Il pagamento è già stato salvato in makePurchase
          resolve(paid)
        })
        .catch(err => reject(err))
    })
  }

  const getPurchaseById = (paymentId) => {
    return new Promise((resolve, reject) => {
      // Cerca per stripeChargeId o _id
      const query = {
        $or: [
          { stripeChargeId: paymentId },
          { _id: paymentId }
        ]
      }
      
      Payment.findOne(query)
        .then(payment => {
          resolve(payment)
        })
        .catch(err => {
          reject(new Error('An error occuered retrieving a payment, err: ' + err))
        })
    })
  }

  const getPayments = (filters = {}) => {
    return new Promise((resolve, reject) => {
      Payment.find(filters)
        .sort({ createdAt: -1 })
        .then(payments => {
          resolve(payments)
        })
        .catch(err => {
          reject(new Error('An error occured retrieving payments, err: ' + err))
        })
    })
  }

  const disconnect = () => {
    mongoose.connection.close()
  }

  return Object.create({
    registerPurchase,
    getPurchaseById,
    getPayments,
    disconnect
  })
}

const connect = () => {
  return new Promise((resolve, reject) => {
    resolve(repository())
  })
}

module.exports = Object.assign({}, {connect})
