# handles venue reservation from user side
module Reservable
  extend ActiveSupport::Concern

  def make_reservation
    unless current_user
      msg = { status: 'error', message: 'Log in to book!', html: '<b>...</b>' }
      render json: msg && return
    end
    paid = true
    reservations, errors = make_reservations(params[:bookings], paid)
    save_reservations(reservations, @venue, paid)
    reservations_response(errors)
  end

  def make_unpaid_reservation
    unless current_user
      msg = { status: 'error', message: 'Log in to book!', html: '<b>...</b>' }
      render json: msg && return
    end

    reservations, errors = make_reservations(params[:bookings])
    save_reservations(reservations, @venue)
    reservations_response(errors)
  end

  private

  def reservations_response(errors)
    if errors.empty?
      render nothing: true, status: :ok
    else
      render json: errors.uniq, status: 402
    end
  end

  def save_reservations(reservations, venue, paid=false)
    Reservation.transaction do
      # what happens if reservatons.valid? is empty ?
      reservations.select(&:valid?).each do |reservation|
        if paid && reservation.game_pass
          reservation.amount_paid = reservation.price
          reservation.is_paid = true
          reservation.game_pass.reload.use!
        end
        reservation.save
        reservation.track_booking
      end
      venue.add_customer(current_user)
    end
  end

  def make_reservations(bookings, paid=false)
    errors = []
    reservations = bookings.values.map do |p|
      if paid
        booking_params = sanitize_booking_params(p, paid)
      else
        booking_params = sanitize_booking_params(p)
      end
      reservation = Reservation.new(booking_params).take_matching_resell
      if paid && !booking_params[:game_pass]
        reservation, error = handle_payment(reservation)
      end
      errors << error unless error.nil?
      reservation
    end
    [reservations, errors]
  end

  def sanitize_booking_params(p, paid=false)
    start_time = TimeSanitizer.input(p[:datetime])
    end_time = start_time + p[:duration].to_i.minutes
    current_court = Court.find(p[:id])
    game_pass = GamePass.find_by_id(p[:game_pass_id])
    if paid
      { start_time: start_time, end_time: end_time,
        court: current_court, price: calculate_price(current_court,
                                                     start_time,
                                                     end_time),
        payment_type: :paid, booking_type: :online,
        user: current_user, game_pass: game_pass }
    else
      { start_time: start_time, end_time: end_time,
        court: current_court, price: calculate_price(current_court,
                                                     start_time,
                                                     end_time),
        payment_type: :unpaid, booking_type: :online,
        user: current_user }
    end

  end

  def calculate_price(court, start_time, end_time)
    discount = current_user.discounts
                           .find_by(venue_id: court.venue
                                                   .id)
    court.price_at(start_time, end_time, discount)
  end

  def handle_payment(reservation)
    error = if reservation.valid?
              reservation.charge(params[:card])
            else
              'Not charging invalid reservation'
            end
    [reservation, error]
  end
end
