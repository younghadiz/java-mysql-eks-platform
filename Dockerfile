FROM amazoncorretto:17-alpine-jdk

EXPOSE 8080
RUN mkdir -p /usr/app
COPY ./build/libs/bootcamp-docker-java-mysql-project-1.0-SNAPSHOT.jar /usr/app
WORKDIR /usr/app

ENTRYPOINT ["java", "-jar", "bootcamp-docker-java-mysql-project-1.0-SNAPSHOT.jar"]