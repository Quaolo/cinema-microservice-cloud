const { createContainer, asValue } = require('awilix')

function initDI ({serverSettings, ecsSettings}, mediator) {
  mediator.once('init', () => {
    console.log('Initializing DI container...')
    console.log('Server settings:', serverSettings)
    console.log('ECS settings:', ecsSettings)
    
    try {
      const container = createContainer()

      container.register({
        ecsSettings: asValue(ecsSettings),
        serverSettings: asValue(serverSettings)
      })

      console.log('DI container registered successfully')
      mediator.emit('di.ready', container)
    } catch (error) {
      console.error('Error initializing DI container:', error)
      console.error('Error stack:', error.stack)
      process.exit(1)
    }
  })
}

module.exports.initDI = initDI
