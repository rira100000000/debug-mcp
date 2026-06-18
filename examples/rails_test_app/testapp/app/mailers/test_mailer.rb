# Dummy mailer used to exercise rails_mail_deliveries / observability.
# Usage from a debug session or console:
#   TestMailer.with(to: "user@example.com", name: "Ada").greeting.deliver_now
class TestMailer < ApplicationMailer
  def greeting
    @name = params[:name] || "there"
    mail(to: params[:to] || "user@example.com", subject: "Hello #{@name}")
  end
end
