# Not paired with a document in the DB, just handles coordinating between
# the stripe property in the user with what's being stored in Stripe.

Handler = require '../commons/Handler'
discountHandler = require './discount_handler'
User = require '../users/User'
utils = require '../lib/utils'

recipientCouponID = 'free'
subscriptions = {
  basic: {
    gems: 3500
    amount: 999 # For calculating incremental quantity before sub creation
  }
}

class SubscriptionHandler extends Handler
  logSubscriptionError: (user, msg) ->
    console.warn "Subscription Error: #{user.get('slug')} (#{user._id}): '#{msg}'"

  subscribeUser: (req, user, done) ->
    if (not req.user) or req.user.isAnonymous() or user.isAnonymous()
      return done({res: 'You must be signed in to subscribe.', code: 403})

    token = req.body.stripe.token
    customerID = user.get('stripe')?.customerID
    if not (token or customerID)
      @logSubscriptionError(user, 'Missing stripe token or customer ID.')
      return done({res: 'Missing stripe token or customer ID.', code: 422})

    # Create/retrieve Stripe customer
    if token
      if customerID
        stripe.customers.update customerID, { card: token }, (err, customer) =>
          if err or not customer
            # should not happen outside of test and production polluting each other
            @logSubscriptionError(user, 'Cannot find customer: ' + customerID + '\n\n' + err)
            return done({res: 'Cannot find customer.', code: 404})
          @checkForExistingSubscription(req, user, customer, done)

      else
        newCustomer = {
          card: token
          email: user.get('email')
          metadata: { id: user._id + '', slug: user.get('slug') }
        }

        stripe.customers.create newCustomer, (err, customer) =>
          if err
            if err.type in ['StripeCardError', 'StripeInvalidRequestError']
              return done({res: 'Card error', code: 402})
            else
              @logSubscriptionError(user, 'Stripe customer creation error. ' + err)
              return done({res: 'Database error.', code: 500})

          stripeInfo = _.cloneDeep(user.get('stripe') ? {})
          stripeInfo.customerID = customer.id
          user.set('stripe', stripeInfo)
          user.save (err) =>
            if err
              @logSubscriptionError(user, 'Stripe customer id save db error. ' + err)
              return done({res: 'Database error.', code: 500})
            @checkForExistingSubscription(req, user, customer, done)

    else
      stripe.customers.retrieve(customerID, (err, customer) =>
        if err
          @logSubscriptionError(user, 'Stripe customer retrieve error. ' + err)
          return done({res: 'Database error.', code: 500})
        @checkForExistingSubscription(req, user, customer, done)
      )

  checkForExistingSubscription: (req, user, customer, done) ->
    # Check if user is subscribing someone else
    if req.body.stripe?.recipientEmail?
      return @updateStripeRecipientSubscription req, user, customer, done

    if user.get('stripe')?.sponsorID
      return done({res: 'You already have a sponsored subscription.', code: 403})

    couponID = user.get('stripe')?.couponID

    # SALE LOGIC
    # overwrite couponID with another for everyone-sales
    #couponID = 'hoc_399' if not couponID

    if subscription = customer.subscriptions?.data?[0]

      if subscription.cancel_at_period_end
        # Things are a little tricky here. Can't re-enable a cancelled subscription,
        # so it needs to be deleted, but also don't want to charge for the new subscription immediately.
        # So delete the cancelled subscription (no at_period_end given here) and give the new
        # subscription a trial period that ends when the cancelled subscription would have ended.
        stripe.customers.cancelSubscription subscription.customer, subscription.id, (err) =>
          if err
            @logSubscriptionError(user, 'Stripe cancel subscription error. ' + err)
            return done({res: 'Database error.', code: 500})

          options = { plan: 'basic', metadata: {id: user.id}, trial_end: subscription.current_period_end }
          options.coupon = couponID if couponID
          stripe.customers.update user.get('stripe').customerID, options, (err, customer) =>
            if err
              @logSubscriptionError(user, 'Stripe customer plan setting error. ' + err)
              return done({res: 'Database error.', code: 500})

            @updateUser(req, user, customer, false, done)

      else
        # can skip creating the subscription
        return @updateUser(req, user, customer, false, done)

    else
      options = { plan: 'basic', metadata: {id: user.id}}
      options.coupon = couponID if couponID
      stripe.customers.update user.get('stripe').customerID, options, (err, customer) =>
        if err
          @logSubscriptionError(user, 'Stripe customer plan setting error. ' + err)
          return done({res: 'Database error.', code: 500})

        @updateUser(req, user, customer, true, done)

  updateUser: (req, user, customer, increment, done) ->
    subscription = customer.subscriptions.data[0]
    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripeInfo.planID = 'basic'
    stripeInfo.subscriptionID = subscription.id
    stripeInfo.customerID = customer.id
    req.body.stripe = stripeInfo # to make sure things work for admins, who are mad with power
    user.set('stripe', stripeInfo)

    if increment
      purchased = _.clone(user.get('purchased'))
      purchased ?= {}
      purchased.gems ?= 0
      purchased.gems += subscriptions.basic.gems # TODO: Put actual subscription amount here
      user.set('purchased', purchased)

    user.save (err) =>
      if err
        @logSubscriptionError(user, 'Stripe user plan saving error. ' + err)
        return done({res: 'Database error.', code: 500})
      user?.saveActiveUser 'subscribe'
      return done()

  updateStripeRecipientSubscription: (req, user, customer, done) ->
    unless req.body.stripe?.recipientEmail?
      return done({res: 'Database error.', code: 500})

    User.findOne {emailLower: req.body.stripe.recipientEmail.toLowerCase()}, (err, recipient) =>
      if err
        @logSubscriptionError(user, "User lookup error. " + err)
        return done({res: 'Database error.', code: 500})
      unless recipient
        @logSubscriptionError(user, "Recipient #{req.body.stripe.recipient} not found. " + err)
        return done({res: 'Not found.', code: 404})

      if recipient.id is user.id
        # TODO: Don't modify the request object
        delete req.body.stripe?.recipientEmail
        return @checkForExistingSubscription(req, user, customer, done)

      # Find existing recipient subscription
      # TODO: This only checks the latest 10 subscriptions.  E.g. resubscribe the 1st recipient of 20 total.
      # TODO: Need to call stripe.customers.listSubscriptions to search all of them
      for sub in customer.subscriptions?.data
        if sub.metadata?.id is recipient.id
          subscription = sub
          break

      if subscription
        if subscription.cancel_at_period_end
          # Things are a little tricky here. Can't re-enable a cancelled subscription,
          # so it needs to be deleted, but also don't want to charge for the new subscription immediately.
          # So delete the cancelled subscription (no at_period_end given here) and give the new
          # subscription a trial period that ends when the cancelled subscription would have ended.
          stripe.customers.cancelSubscription subscription.customer, subscription.id, (err) =>
            if err
              @logSubscriptionError(user, 'Stripe cancel subscription error. ' + err)
              return done({res: 'Database error.', code: 500})

            options =
              plan: 'basic'
              coupon: recipientCouponID
              metadata: {id: recipient.id}
              trial_end: subscription.current_period_end
            stripe.customers.createSubscription customer.id, options, (err, subscription) =>
              if err
                @logSubscriptionError(user, 'Stripe new subscription error. ' + err)
                return done({res: 'Database error.', code: 500})
              @updateCocoRecipientSubscription(req, user, customer, false, subscription, recipient, done)
        else
          # Can skip creating the subscription
          @updateCocoRecipientSubscription(req, user, customer, false, subscription, recipient, done)

      else
        options =
          plan: 'basic'
          coupon: recipientCouponID
          metadata: {id: recipient.id}
        stripe.customers.createSubscription customer.id, options, (err, subscription) =>
          if err
            @logSubscriptionError(user, 'Stripe new subscription error. ' + err)
            return done({res: 'Database error.', code: 500})
          @updateCocoRecipientSubscription(req, user, customer, true, subscription, recipient, done)

  updateCocoRecipientSubscription: (req, user, customer, increment, subscription, recipient, done) ->
    # Update recipients list
    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripeInfo.recipients ?= []
    _.remove(stripeInfo.recipients, (s) -> s.userID is recipient.id)
    stripeInfo.recipients.push
      userID: recipient.id
      planID: subscription.plan.id
      subscriptionID: subscription.id
      couponID: recipientCouponID
    user.set('stripe', stripeInfo)
    user.save (err) =>
      if err
        @logSubscriptionError(user, 'User saving stripe error. ' + err)
        return done({res: 'Database error.', code: 500})

      # Update recipient
      stripeInfo = _.cloneDeep(recipient.get('stripe') ? {})
      stripeInfo.sponsorID = user.id
      recipient.set 'stripe', stripeInfo
      if increment
        purchased = _.clone(recipient.get('purchased'))
        purchased ?= {}
        purchased.gems ?= 0
        purchased.gems += subscriptions.basic.gems
        recipient.set('purchased', purchased)
      recipient.save (err) =>
        if err
          @logSubscriptionError(user, 'Stripe user saving stripe error. ' + err)
          return done({res: 'Database error.', code: 500})

        @updateStripeSponsorSubscription(req, user, customer, done)

  updateStripeSponsorSubscription: (req, user, customer, done) ->
    stripeInfo = user.get('stripe') ? {}
    numSponsored = stripeInfo.recipients.length
    quantity = utils.getSponsoredSubsAmount(subscriptions.basic.amount, numSponsored, stripeInfo.subscriptionID?)

    # TODO: Use stripe.customers.listSubscriptions instead of only recent 10 on customer.subscriptions
    # TODO: Cancelling 11 recipient subs in a row would theoretically flush the sponsor sub out of most recent 10
    # TODO: Subscribing a bunch keeps the sponsor sub in the most recent 10 because it gets an updated quantity for each
    if stripeInfo.sponsorSubscriptionID?
      for sub in customer.subscriptions?.data
        if stripeInfo.sponsorSubscriptionID is sub.id
          subscription = sub
          break
      unless subscription?
        @logSubscriptionError(user, "Internal sponsor subscription #{stripeInfo.sponsorSubscriptionID} not found on Stripe customer #{customer.id}")
        return done({res: 'Database error.', code: 500})

    if subscription
      return done() if quantity is subscription.quantity # E.g. cancelled sub has been resubbed

      options = quantity: quantity
      stripe.customers.updateSubscription customer.id, stripeInfo.sponsorSubscriptionID, options, (err, subscription) =>
        if err
          @logSubscriptionError(user, 'Stripe updating subscription quantity error. ' + err)
          return done({res: 'Database error.', code: 500})

        # Invoice proration immediately
        stripe.invoices.create customer: customer.id, (err, invoice) =>
          if err
            @logSubscriptionError(user, 'Stripe proration invoice error. ' + err)
            return done({res: 'Database error.', code: 500})
          done()
    else
      options =
        plan: 'incremental'
        metadata: {id: user.id}
        quantity: quantity
      stripe.customers.createSubscription customer.id, options, (err, subscription) =>
        if err
          @logSubscriptionError(user, 'Stripe new subscription error. ' + err)
          return done({res: 'Database error.', code: 500})
        @updateCocoSponsorSubscription(req, user, subscription, done)

  updateCocoSponsorSubscription: (req, user, subscription, done) ->
    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripeInfo.sponsorSubscriptionID = subscription.id
    user.set('stripe', stripeInfo)
    user.save (err) =>
      if err
        @logSubscriptionError(user, 'Saving user stripe error. ' + err)
        return done({res: 'Database error.', code: 500})
      done()

  unsubscribeUser: (req, user, done) ->
    # Check if user is subscribing someone else
    return @unsubscribeRecipient(req, user, done) if req.body.stripe?.recipientEmail?

    stripeInfo = _.cloneDeep(user.get('stripe') ? {})
    stripe.customers.cancelSubscription stripeInfo.customerID, stripeInfo.subscriptionID, { at_period_end: true }, (err) =>
      if err
        @logSubscriptionError(user, 'Stripe cancel subscription error. ' + err)
        return done({res: 'Database error.', code: 500})
      delete stripeInfo.planID
      user.set('stripe', stripeInfo)
      req.body.stripe = stripeInfo
      user.save (err) =>
        if err
          @logSubscriptionError(user, 'User save unsubscribe error. ' + err)
          return done({res: 'Database error.', code: 500})
        done()

  unsubscribeRecipient: (req, user, done) ->
    return done({res: 'Database error.', code: 500}) unless req.body.stripe?.recipientEmail?

    User.findOne {emailLower: req.body.stripe.recipientEmail.toLowerCase()}, (err, recipient) =>
      if err
        @logSubscriptionError(user, "User lookup error. " + err)
        return done({res: 'Database error.', code: 500})
      unless recipient
        @logSubscriptionError(user, "Recipient #{req.body.stripe.recipient} not found. " + err)
        return done({res: 'Database error.', code: 500})

      # Check recipient is currently sponsored
      stripeRecipient = recipient.get 'stripe' ? {}
      if stripeRecipient.sponsorID isnt user.id
        @logSubscriptionError(user, "Recipient #{req.body.stripe.recipient} not found. " + err)
        return done({res: 'Can only unsubscribe sponsored subscriptions.', code: 403})

      # Find recipient subscription
      stripeInfo = _.cloneDeep(user.get('stripe') ? {})
      for sponsored in stripeInfo.recipients
        if sponsored.userID is recipient.id
          sponsoredEntry = sponsored
          delete sponsored.planID
          break
      unless sponsoredEntry?
        @logSubscriptionError(user, 'Unable to find sponsored subscription. ' + err)
        return done({res: 'Database error.', code: 500})

      # Cancel Stripe subscription
      stripe.customers.cancelSubscription stripeInfo.customerID, sponsoredEntry.subscriptionID, { at_period_end: true }, (err) =>
        if err or not recipient
          @logSubscriptionError(user, "Stripe cancel sponsored subscription failed. " + err)
          return done({res: 'Database error.', code: 500})

        # Update recipients entry (planID deleted above)
        user.set('stripe', stripeInfo)
        req.body.stripe = stripeInfo
        user.save (err) =>
          if err
            @logSubscriptionError(user, 'User save unsubscribe error. ' + err)
            return done({res: 'Database error.', code: 500})
          done()

module.exports = new SubscriptionHandler()
