import 'campus_map_data.dart';
import 'shuttle_models.dart';

/// 人工确认的十三组双向站点，直接使用最终 WGS84 坐标。
const shuttleStations = <ShuttleStation>[
  ShuttleStation(
    id: 'nuist-bus-stop-01',
    name: '行政楼南',
    first: GeoPoint(longitude: 118.71905, latitude: 32.20571),
    second: GeoPoint(longitude: 118.71915, latitude: 32.20579),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-02',
    name: '气象楼南',
    first: GeoPoint(longitude: 118.717, latitude: 32.205),
    second: GeoPoint(longitude: 118.7179, latitude: 32.205),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-03',
    name: '气象谷',
    first: GeoPoint(longitude: 118.71347, latitude: 32.205),
    second: GeoPoint(longitude: 118.71378, latitude: 32.20492),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-04',
    name: '中苑老食堂',
    first: GeoPoint(longitude: 118.71127, latitude: 32.20473),
    second: GeoPoint(longitude: 118.71076, latitude: 32.2046),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-05',
    name: '图书馆',
    first: GeoPoint(longitude: 118.70806, latitude: 32.20422),
    second: GeoPoint(longitude: 118.70846, latitude: 32.2042),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-06',
    name: '逸夫楼',
    first: GeoPoint(longitude: 118.70627, latitude: 32.20368),
    second: GeoPoint(longitude: 118.70606, latitude: 32.20346),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-07',
    name: '滨江楼',
    first: GeoPoint(longitude: 118.70346, latitude: 32.20241),
    second: GeoPoint(longitude: 118.70286, latitude: 32.202),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-08',
    name: '滨江食堂',
    first: GeoPoint(longitude: 118.70164, latitude: 32.20568),
    second: GeoPoint(longitude: 118.7013, latitude: 32.2058),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-09',
    name: '人才公寓',
    first: GeoPoint(longitude: 118.70706, latitude: 32.20576),
    second: GeoPoint(longitude: 118.70724, latitude: 32.20588),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-10',
    name: '明德楼',
    first: GeoPoint(longitude: 118.71321, latitude: 32.20652),
    second: GeoPoint(longitude: 118.71356, latitude: 32.20664),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-11',
    name: '文德楼',
    first: GeoPoint(longitude: 118.71579, latitude: 32.20683),
    second: GeoPoint(longitude: 118.71563, latitude: 32.20692),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-12',
    name: '气象楼北',
    first: GeoPoint(longitude: 118.7172, latitude: 32.20697),
    second: GeoPoint(longitude: 118.71718, latitude: 32.20706),
  ),
  ShuttleStation(
    id: 'nuist-bus-stop-13',
    name: '行政楼北',
    first: GeoPoint(longitude: 118.71913, latitude: 32.20718),
    second: GeoPoint(longitude: 118.71893, latitude: 32.20726),
  ),
];
