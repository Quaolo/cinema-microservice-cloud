'use strict'

const AWS = require('aws-sdk')

// Configurazione: regione e bucket
const s3 = new AWS.S3({ region: process.env.AWS_REGION || 'eu-west-1' })
const BUCKET = process.env.MOVIE_IMAGES_BUCKET || 'cinema-posters-123456789'

const getPosterUrl = async (movieId) => {
  const key = `movies/movie${movieId}.txt`  // i file caricati nello script deploy
  try {
    const data = await s3.getObject({ Bucket: BUCKET, Key: key }).promise()
    // Il file contiene solo l'URL (stringa)
    return data.Body.toString('utf-8').trim()
  } catch (err) {
    console.error(`S3: errore nel recupero poster per ID=${movieId}`, err)
    return null
  }
}

module.exports = { getPosterUrl }
