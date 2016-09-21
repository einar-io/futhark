-- Date computations.  Some complex scalar expressions and a branch.
-- Once messed up the simplifier.

fun mod(x: int, y: int): int = x - (x/y)*y

val hours_in_dayI: int = 24
val minutes_in_dayI: int = hours_in_dayI * 60
val minutes_to_noonI: int = (hours_in_dayI / 2) * 60
val minutes_in_day: f64 = 24.0*60.0

fun date_of_gregorian(date:  (int,int,int,int,int)): int =
  let (year, month, day, hour, mins) = date
  let ym =
      if(month == 1 || month == 2)
      then    ( 1461 * ( year + 4800 - 1 ) ) / 4 +
                ( 367 * ( month + 10 ) ) / 12 -
                ( 3 * ( ( year + 4900 - 1 ) / 100 ) ) / 4
      else    ( 1461 * ( year + 4800 ) ) / 4 +
                ( 367 * ( month - 2 ) ) / 12 -
                ( 3 * ( ( year + 4900 ) / 100 ) ) / 4
  let tmp = ym + day - 32075 - 2444238

  in tmp * minutes_in_dayI + hour * 60 + mins

fun gregorian_of_date (minutes_since_epoch:  int ): (int,int,int,int,int) =
  let jul = minutes_since_epoch / minutes_in_dayI
  let l = jul + 68569 + 2444238
  let n = ( 4 * l ) / 146097
  let l = l - ( 146097 * n + 3 ) / 4
  let i = ( 4000 * ( l + 1 ) ) / 1461001
  let l = l - ( 1461 * i ) / 4 + 31
  let j = ( 80 * l ) / 2447
  let d = l - ( 2447 * j ) / 80
  let l = j / 11
  let m = j + 2 - ( 12 * l )
  let y = 100 * ( n - 49 ) + i + l

  --let daytime = minutes_since_epoch mod minutes_in_day in
  let daytime = mod( minutes_since_epoch, minutes_in_dayI ) in

  if ( daytime == minutes_to_noonI )

  --then [year = y; month = m; day = d; hour = 12; minute = 0]
  then (y, m, d, 12, 0)

  --else [year = y; month = m; day = d; hour = daytime / 60; minute = daytime mod 60]
  else (y, m, d, daytime / 60, mod(daytime, 60) )

fun main(x: int): int =
  date_of_gregorian(gregorian_of_date(x))
