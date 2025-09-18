'use strict'

const discoverRoutes = (container) => {
  return new Promise((resolve, reject) => {
    try {
      const ecsSettings = container.resolve('ecsSettings')
      
      // Return the static service configuration
      const routes = new Proxy(ecsSettings.services, {
        get (target, key) {
          console.log(`Get properties from -> "${key}" service`)
          return Reflect.get(target, key)
        },
        set (target, key, value) {
          console.log('Setting properties', key, value)
          return Reflect.set(target, key, value)
        }
      })

      console.log('ECS Service Discovery: Routes configured for ECS services')
      console.log('Available services:', Object.keys(routes))
      
      resolve(routes)
    } catch (error) {
      reject(new Error('Error configuring ECS service discovery: ' + error.message))
    }
  })
}

module.exports = Object.assign({}, {discoverRoutes})
